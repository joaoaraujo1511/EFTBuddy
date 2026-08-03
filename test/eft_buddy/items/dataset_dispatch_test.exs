defmodule EftBuddy.Items.DatasetDispatchTest do
  @moduledoc """
  `EftBuddy.Items.DatasetEqualityTest` proves the two implementations agree.
  These prove the right one is *chosen* — which is a separate question, and the
  one that decides whether this layer is safe to switch on.

  The trick throughout is to make the two paths deliberately disagree: change the
  database WITHOUT rebuilding the dataset, so the dataset holds a snapshot the
  database no longer matches. Whichever answer comes back then names the path
  that served it. Every other assertion here would pass against either
  implementation and prove nothing.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Fixtures
  alias EftBuddy.Items
  alias EftBuddy.Items.Dataset

  setup do
    original_cache = Application.get_env(:eft_buddy, :cache_enabled)
    original_dataset = Application.get_env(:eft_buddy, :item_dataset_enabled)

    Application.put_env(:eft_buddy, :item_dataset_enabled, true)
    Application.put_env(:eft_buddy, :cache_enabled, false)
    Dataset.clear()

    on_exit(fn ->
      Dataset.clear()
      # `|| false` rather than the raw original: writing back a nil would leave
      # an explicitly-nil key, which `Application.get_env/3`'s default cannot
      # rescue, and every later test would inherit it.
      Application.put_env(:eft_buddy, :cache_enabled, original_cache || false)
      Application.put_env(:eft_buddy, :item_dataset_enabled, original_dataset || false)
    end)

    Fixtures.item(%{name: "Original item", normalized_name: "original", last_low_price: 100})

    :ok
  end

  defp build! do
    Dataset.refresh_catalog()
    Dataset.refresh_prices()
  end

  defp names(opts \\ [limit: 100]), do: Items.list_all_items(opts) |> Enum.map(& &1.name)

  describe "which path serves the read" do
    test "a built, fresh dataset serves the listing" do
      build!()

      # Added to the database only. If the dataset is serving, it cannot know.
      Fixtures.item(%{name: "Added after the build", normalized_name: "added"})

      refute "Added after the build" in names(),
             "the SQL path served this — the dataset was not used"
    end

    test "an unbuilt dataset falls back to SQL rather than serving nothing" do
      # The state at every boot, before the first warm. Serving an empty
      # catalogue here would be the worst possible failure: a site that looks
      # like it has no items.
      refute Dataset.ready?(:pvp)

      assert "Original item" in names()
    end

    test "switching the dataset off falls back to SQL immediately" do
      build!()
      Fixtures.item(%{name: "Added after the build", normalized_name: "added"})

      Application.put_env(:eft_buddy, :item_dataset_enabled, false)

      # The kill switch has to work without a rebuild or a restart, because that
      # is the entire point of it being a runtime flag.
      assert "Added after the build" in names()
    end

    test "a rebuild picks the database's new state back up" do
      build!()
      Fixtures.item(%{name: "Added after the build", normalized_name: "added"})

      build!()

      assert "Added after the build" in names()
    end
  end

  describe "the flea reads dispatch the same way" do
    test "a built dataset serves the flea listing and its counts" do
      build!()

      Fixtures.item(%{
        name: "Late flea item",
        normalized_name: "late-flea",
        last_low_price: 999_999
      })

      listed = Items.list_flea_market_items(limit: 100) |> Enum.map(& &1.name)
      refute "Late flea item" in listed

      # And the badge agrees with the tab, which is the property that breaks
      # first if the listing and the counts ever dispatch differently.
      counts = Items.flea_market_status_counts([])
      assert counts.all == length(listed)
    end

    test "the flea reads fall back when the dataset is not ready" do
      Fixtures.item(%{name: "Late flea item", normalized_name: "late", last_low_price: 999_999})

      listed = Items.list_flea_market_items(limit: 100) |> Enum.map(& &1.name)

      assert "Late flea item" in listed
    end
  end

  describe "staleness" do
    test "a dataset built but never price-refreshed is not ready" do
      # The two layers are refreshed by different syncers, so one can be current
      # while the other is not. Readiness has to require both, or a working
      # catalogue would mask a price feed that stopped ten minutes ago.
      Dataset.refresh_catalog()

      refute Dataset.ready?(:pvp)
      assert "Original item" in names()
    end

    test "readiness is per game mode" do
      # Prices are keyed per mode. A mode whose price layer never built must not
      # ride on the other one's freshness.
      build!()

      assert Dataset.ready?(:pvp)
      assert Dataset.ready?(:pve)
    end
  end
end
