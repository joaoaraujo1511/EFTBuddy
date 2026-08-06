defmodule EftBuddy.Items.DatasetFailureTest do
  @moduledoc """
  What the in-memory layer does when a rebuild dies partway.

  This is the regression suite for a real incident: the Flea Market page rendered
  every item with correct names, icons and categories, and `-` for every single
  price. `EftBuddy.Items.DatasetDispatchTest` proves the right path is chosen and
  `DatasetEqualityTest` proves the two paths agree — neither can see this, because
  both only ever exercise builds that succeed.

  The mechanism was that `refresh_prices/0` emptied the price table *before* it
  queried. A dropped connection then raised with the table already empty, while
  `prices_built_at` still held the previous run's timestamp — so `ready?/1`
  answered true over nothing and `overlay_price(item, nil)` nilled every price
  field. It self-healed on the next ten-minute tick, which is why it presented as
  a mystery rather than an outage.

  The rule these tests encode: **a build that does not finish must leave the layer
  not-ready, never ready-and-empty.** Falling back to SQL costs latency. Serving an
  empty layer costs correctness, silently.

  ## On the failure injection

  Renaming a table out from under a query is crude, but it is the only injection
  available here. `EftBuddy.DataCase` runs `async: false` tests with a *shared*
  sandbox connection, so the usual trick — do the work in an unallowed process and
  let `DBConnection.OwnershipError` fire before any SQL is sent — cannot work: a
  spawned process would simply inherit the connection and succeed.

  The consequence is that the failing statement aborts the sandbox transaction, so
  **no assertion after the injection may touch the database**. That is not a
  limitation here, it is the point: every post-failure assertion below reads ETS
  (`ready?/1`, `stats/0`, and a listing served from memory), and a listing that
  fell through to SQL instead would fail loudly rather than quietly pass.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Fixtures
  alias EftBuddy.Items
  alias EftBuddy.Items.Dataset
  alias EftBuddy.Items.ItemPrice

  @meta :eft_buddy_dataset_meta

  setup do
    original_cache = Application.get_env(:eft_buddy, :cache_enabled)
    original_dataset = Application.get_env(:eft_buddy, :item_dataset_enabled)

    Application.put_env(:eft_buddy, :item_dataset_enabled, true)
    Application.put_env(:eft_buddy, :cache_enabled, false)
    Dataset.clear()

    on_exit(fn ->
      Dataset.clear()
      Application.put_env(:eft_buddy, :cache_enabled, original_cache || false)
      Application.put_env(:eft_buddy, :item_dataset_enabled, original_dataset || false)
    end)

    item =
      Fixtures.item(%{name: "Priced item", normalized_name: "priced", last_low_price: 100})

    Fixtures.item_price(%{item_id: item.id, game_mode: "pve", last_low_price: 200})

    %{item: item}
  end

  defp build! do
    Dataset.refresh_catalog()
    Dataset.refresh_prices()
  end

  defp prices, do: Items.list_flea_market_items(limit: 50) |> Enum.map(& &1.last_low_price)

  describe "a price rebuild that dies partway" do
    test "leaves the previous layer intact, fresh and serving", %{item: item} do
      build!()
      assert prices() == [100], "precondition: the dataset is serving real prices"
      before = Dataset.stats()

      log =
        capture_log(fn ->
          Repo.query!("ALTER TABLE item_prices RENAME TO item_prices_broken")
          assert_raise Postgrex.Error, fn -> Dataset.refresh_prices() end
        end)

      # From here: ETS only. The sandbox transaction is aborted.
      assert log =~ "price refresh failed",
             "the rescue in build/2 is the only trace this failure leaves"

      assert Dataset.ready?(:pvp),
             "the layer was never touched, so it is still as fresh as it was"

      assert Dataset.stats().price_rows == before.price_rows,
             "a failure before the swap must not have destroyed anything"

      assert prices() == [100], "THE INCIDENT: this returned [nil] before the fix"
      assert Dataset.item_with_price(item.id, :pvp).last_low_price == 100
    end

    test "clears the building flag even though it raised" do
      build!()

      capture_log(fn ->
        Repo.query!("ALTER TABLE item_prices RENAME TO item_prices_broken")
        assert_raise Postgrex.Error, fn -> Dataset.refresh_prices() end
      end)

      refute Dataset.stats().building,
             "a stuck flag means permanent SQL fallback — the `after` still owns this"
    end
  end

  describe "a catalogue rebuild that dies partway" do
    test "leaves the previous catalogue standing rather than emptying it" do
      build!()
      before = Dataset.stats()

      log =
        capture_log(fn ->
          Repo.query!("ALTER TABLE items RENAME TO items_broken")
          assert_raise Postgrex.Error, fn -> Dataset.refresh_catalog() end
        end)

      assert log =~ "catalogue refresh failed"
      assert Dataset.ready?(:pvp)
      assert Dataset.stats().items == before.items

      # The catalogue twin of the price incident, and the longer-lived one: the
      # staleness bound here is twelve hours, not sixty minutes, so a ready-but-empty
      # catalogue would have served "no results" for most of a day.
      assert prices() == [100]
    end
  end

  describe "an empty query result" do
    test "does not replace a populated price layer" do
      build!()
      Repo.delete_all(ItemPrice)

      log = capture_log(fn -> Dataset.refresh_prices() end)

      assert log =~ "refusing to replace"

      assert prices() == [100],
             "a successful query returning nothing is indistinguishable from a " <>
               "truncated one; the previous layer is the safer answer"
    end

    test "does not empty a populated catalogue" do
      build!()
      Repo.delete_all(ItemPrice)
      Repo.delete_all(Items.Item)

      log = capture_log(fn -> Dataset.refresh_catalog() end)

      assert log =~ "refusing to replace"
      assert Dataset.stats().items == 1
    end

    test "is still accepted on a cold start, when there is nothing to protect" do
      # `current == 0` must never be blocked, or the layer could never populate on
      # a fresh node. Same exemption `Sync.Helpers.cleanup_safe?/3` makes upstream.
      Repo.delete_all(ItemPrice)
      Dataset.clear()

      refute capture_log(fn -> build!() end) =~ "refusing to replace"
      assert Dataset.ready?(:pvp)
    end
  end

  describe "per-mode isolation" do
    test "a mode whose layer is not stamped is not ready, and only that mode" do
      # The price stamp is per-mode, which is what contains a per-mode failure. It
      # used to be a single global `delete_all_objects/1` up front, so a PVE query
      # failing after PVP had already refilled blanked prices for both audiences.
      build!()
      assert Dataset.ready?(:pvp) and Dataset.ready?(:pve)

      :ets.delete(@meta, {:prices_built_at, "pve"})

      assert Dataset.ready?(:pvp), "PVP's layer is untouched and must keep serving"
      refute Dataset.ready?(:pve)
    end

    test "rebuilding one mode does not drop the other's rows" do
      build!()
      total = Dataset.stats().price_rows
      assert total == 2, "precondition: one row per mode"

      Dataset.refresh_prices()

      assert Dataset.stats().price_rows == total,
             "match_delete must be scoped to the mode being replaced"
    end
  end

  describe "the read paths when a layer is not ready" do
    test "the item detail panel falls back to SQL rather than showing blank prices",
         %{item: item} do
      build!()
      :ets.delete(@meta, {:prices_built_at, "regular"})

      # `item_with_price/2` returns nil when not ready, so the `||` in
      # `Items.resolve_item/2` falls through. Were it to return a struct with nil
      # prices instead, that `||` would see a truthy value and the panel would
      # render blanks in exactly the window the listing was blank.
      assert Items.get_item_details(item.id, :pvp).item.last_low_price == 100
    end

    test "the flea listing falls back to SQL" do
      build!()
      :ets.delete(@meta, {:prices_built_at, "regular"})

      assert prices() == [100]
    end
  end
end
