defmodule EftBuddy.Items.SyncPriceGuardTest do
  @moduledoc """
  The price write path, which had no test coverage of any kind.

  `refresh_item_prices_flea/3` upserts with
  `on_conflict: {:replace, [:last_low_price, …]}`, so a nil `lastLowPrice` in the
  upstream document is written over a live price as a NULL. The dangerous input is
  therefore NOT a short response — that produces no rows and writes nothing — but a
  **full-size response whose price fields have been stripped**. It changes no row
  count, so `cleanup_safe?/3` could never have seen it, and the run reported `ok`
  with a healthy-looking `upserted:` figure while the whole catalogue went to NULL.

  These tests are written against the guard's behaviour at the call site, which is
  the half `EftBuddy.Sync.HelpersTest` cannot reach: a guard that returns
  `{:skip, _}` and is then ignored passes every unit test it has.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias EftBuddy.Fixtures
  alias EftBuddy.Items.ItemPrice
  alias EftBuddy.Items.Sync
  alias EftBuddy.Sync.Reporter

  setup do
    # `with_run/2` writes to the global status table, and the refusal counter only
    # survives into a run's record if there IS a run — so these tests must reset it
    # like any other test that records one.
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)

    items =
      for n <- 1..20 do
        Fixtures.item(%{
          name: "Item #{n}",
          normalized_name: "item-guard-#{n}",
          last_low_price: 100 + n
        })
      end

    %{items: items}
  end

  # The shape `TarkovApi.flea_prices/1` returns: one map per catalogue item.
  defp document(items, price_fun) do
    Enum.map(items, fn item ->
      %{
        "id" => item.external_id,
        "lastLowPrice" => price_fun.(item),
        "avg24hPrice" => price_fun.(item),
        "low24hPrice" => price_fun.(item),
        "high24hPrice" => price_fun.(item)
      }
    end)
  end

  # Wrapped in a real `with_run/2` because the refusal only reaches the run record
  # through `Reporter.count_refusal/0`, which is a no-op outside one — so calling
  # the write bare would test the guard's return value and none of its reporting.
  defp write(raw, mode \\ "regular") do
    {{:ok, summary}, log} =
      with_log(fn ->
        Reporter.with_run("PricesSync", fn ->
          {:ok, Sync.refresh_item_prices_flea(Repo, raw, mode)}
        end)
      end)

    {summary, log, Reporter.status()["PricesSync"]}
  end

  defp priced_count(mode \\ "regular") do
    Repo.aggregate(
      from(p in ItemPrice, where: p.game_mode == ^mode and not is_nil(p.last_low_price)),
      :count,
      :id
    )
  end

  describe "a null-stripped document" do
    test "does not wipe the catalogue's prices", %{items: items} do
      assert priced_count() == 20, "precondition: every item is priced"

      raw = document(items, fn _ -> nil end)
      {summary, log, _status} = write(raw)

      assert priced_count() == 20,
             "THE FAILURE THIS GUARDS: 20 live prices replaced by NULL in one pass"

      assert summary.upserted == 0
      assert summary.refused
      assert log =~ "Refusing regular price write"
      assert log =~ "null-stripped"
    end

    test "records a refusal on the run, so it reaches /health/sync", %{items: items} do
      {_summary, _log, status} = write(document(items, fn _ -> nil end))

      # The counter on the RUN RECORD is what survives into the readiness verdict.
      # A `Logger.error` alone reaches nobody, which was the state of affairs the
      # refusal mechanism exists to end. (Its rendering as `REFUSED-PRUNES=n` on the
      # summary line is Reporter's business and is logged at :info, below the test
      # env's `:warning` threshold.)
      assert status.refusals >= 1

      verdict =
        EftBuddy.Sync.Freshness.evaluate(
          status: Reporter.status(),
          uptime_seconds: 60
        )

      assert verdict.syncs["PricesSync"].state == :guard_tripped
      assert verdict.status == :degraded
    end

    test "leaves the accumulated price history untouched", %{items: items} do
      # `append_history/3` already returns the previous series unchanged for a nil
      # price, so history was never the exposure — pinned so a future refactor of
      # the refusal branch cannot quietly start truncating sparklines.
      before = Repo.all(from(p in ItemPrice, select: p.historical_prices))

      write(document(items, fn _ -> nil end))

      assert Repo.all(from(p in ItemPrice, select: p.historical_prices)) == before
    end
  end

  describe "documents that must still be written" do
    test "a healthy document updates every price", %{items: items} do
      {summary, _log, status} = write(document(items, fn _ -> 999 end))

      assert summary.upserted == 20
      refute Map.has_key?(summary, :refused)
      assert status.refusals == 0

      assert Repo.aggregate(
               from(p in ItemPrice, where: p.game_mode == "regular" and p.last_low_price == 999),
               :count,
               :id
             ) == 20
    end

    test "a document that drops a few prices still writes", %{items: items} do
      # 19 of 20 priced is 95%, above the 0.9 floor. Items get delisted from the
      # flea legitimately, and a guard that fired on that would be useless.
      [first | _] = items
      raw = document(items, fn item -> if item.id == first.id, do: nil, else: 500 end)

      {summary, _log, _status} = write(raw)

      assert summary.upserted == 20
      assert priced_count() == 19, "the one genuine delisting landed"
    end

    test "a cold start with nothing priced yet is never blocked", %{items: items} do
      Repo.update_all(ItemPrice, set: [last_low_price: nil])
      assert priced_count() == 0

      {summary, _log, _status} = write(document(items, fn _ -> 777 end))

      assert summary.upserted == 20
      assert priced_count() == 20
    end
  end

  describe "per-mode isolation" do
    test "a bad PVE document does not block a good PVP one", %{items: items} do
      for item <- items do
        Fixtures.item_price(%{item_id: item.id, game_mode: "pve", last_low_price: 50})
      end

      {pve, _log, _status} = write(document(items, fn _ -> nil end), "pve")
      {pvp, _log, _status} = write(document(items, fn _ -> 321 end), "regular")

      assert pve.refused, "the mode with the bad document is refused"
      assert pvp.upserted == 20, "and the mode with a good one is written"

      assert priced_count("pve") == 20
      assert priced_count("regular") == 20
    end
  end
end
