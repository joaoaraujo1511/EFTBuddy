defmodule EftBuddyWeb.CacheDashboardPageTest do
  @moduledoc """
  The cache page lives behind an SSH tunnel on an endpoint the test suite never
  starts, so without this it would be the one surface in the app whose first
  real render happens in production — during whatever incident prompted someone
  to open it.

  Rendering it here catches the failures a compile cannot: a slot passed wrongly
  to a LiveDashboard component, a helper that blows up on an empty table, a
  format function fed a value it does not have a clause for.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias EftBuddy.Cache
  alias EftBuddyWeb.CacheDashboardPage

  setup do
    original = Application.get_env(:eft_buddy, :cache_enabled)
    Application.put_env(:eft_buddy, :cache_enabled, true)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      Application.put_env(:eft_buddy, :cache_enabled, original)
    end)

    :ok
  end

  defp render_page do
    render_component(&CacheDashboardPage.render/1,
      stats: Cache.stats(),
      entries: Cache.entries(),
      specs: EftBuddy.Cache.Warmer.default_specs(),
      dataset: EftBuddy.Items.Dataset.stats()
    )
  end

  # The dataset panel's "nothing built" state, which is what the page shows
  # whenever the layer is switched off — i.e. by default.
  defp blank_dataset do
    %{
      enabled: false,
      building: false,
      items: 0,
      price_rows: 0,
      catalog_age_ms: nil,
      memory_bytes: 0
    }
  end

  test "renders with an empty cache" do
    # The state the page is in immediately after every sync, and the one most
    # likely to hit an unguarded helper clause.
    html = render_page()

    assert html =~ "Hit rate"
    assert html =~ "Empty."
  end

  test "renders entries with their owning syncers, ages and TTLs" do
    Cache.fetch({:dash_test, :entry}, ["ItemsSync", "PricesSync"], fn -> :value end)

    html = render_page()

    assert html =~ "ItemsSync, PricesSync"
    assert html =~ ":dash_test"
  end

  test "never renders the cached values themselves" do
    # Values can be megabytes each. Rendering them would make looking at the
    # cache more expensive than using it — and on this page, would dump the
    # entire item catalogue into an operator's browser.
    Cache.fetch({:dash_test, :big}, ["ItemsSync"], fn -> :a_very_distinctive_value end)

    refute render_page() =~ "a_very_distinctive_value"
  end

  test "shows a dash, not 0%, when nothing has been read yet" do
    # "Nothing has been asked for" and "every read missed" are opposite
    # diagnoses; rendering both as 0% would make the page actively misleading.
    html =
      render_component(&CacheDashboardPage.render/1,
        stats: %{
          entries: 0,
          memory_bytes: 0,
          hits: 0,
          misses: 0,
          hit_rate: nil,
          enabled: true
        },
        entries: [],
        specs: [],
        dataset: blank_dataset()
      )

    assert html =~ "—"
  end

  test "says so loudly when the cache is switched off" do
    html =
      render_component(&CacheDashboardPage.render/1,
        stats: %{
          entries: 0,
          memory_bytes: 0,
          hits: 0,
          misses: 0,
          hit_rate: nil,
          enabled: false
        },
        entries: [],
        specs: [],
        dataset: blank_dataset()
      )

    assert html =~ "DISABLED"
  end

  test "renders the warm registry so an unwarmed dataset is visible as absence" do
    html = render_page()

    assert html =~ "hideout.modules"
    assert html =~ "HideoutSync"
  end
end
