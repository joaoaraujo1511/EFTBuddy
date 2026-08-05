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
  alias EftBuddy.Cache.Warmer
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
      coverage: EftBuddy.Cache.Warmer.coverage(),
      summary: EftBuddy.Cache.Warmer.coverage_summary(),
      dataset: EftBuddy.Items.Dataset.stats()
    )
  end

  # A freshly-booted cache: nothing read, nothing written.
  defp blank_stats do
    %{
      entries: 0,
      warm_entries: 0,
      read_entries: 0,
      max_entries: 20_000,
      memory_bytes: 0,
      hits: 0,
      misses: 0,
      warm_hits: 0,
      warm_misses: 0,
      warm_writes: 0,
      hit_rate: nil,
      enabled: true
    }
  end

  defp blank_summary, do: %{total: 0, live: 0, cold: []}

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
        stats: blank_stats(),
        entries: [],
        coverage: [],
        summary: blank_summary(),
        dataset: blank_dataset()
      )

    assert html =~ "—"
  end

  test "says so loudly when the cache is switched off" do
    html =
      render_component(&CacheDashboardPage.render/1,
        stats: %{blank_stats() | enabled: false},
        entries: [],
        coverage: [],
        summary: blank_summary(),
        dataset: blank_dataset()
      )

    assert html =~ "DISABLED"
  end

  test "renders the warm registry so an unwarmed dataset is visible as absence" do
    # The test env registry is empty (config/test.exs), so point the page at the
    # REAL one. `coverage/0` only probes — it never runs a spec — so this cannot
    # touch the database. Restored on exit so a later flush cannot reach a spec
    # that would.
    original = Application.get_env(:eft_buddy, :cache_warm_specs)
    Application.put_env(:eft_buddy, :cache_warm_specs, Warmer.default_specs())
    on_exit(fn -> Application.put_env(:eft_buddy, :cache_warm_specs, original || []) end)

    html = render_page()

    assert html =~ "hideout.modules"
    assert html =~ "HideoutSync"
  end

  test "the coverage card names the specs that are cold" do
    # The signal the whole warming rework turns on: entry count, memory and hit
    # rate can all look healthy while most of the registry has quietly expired.
    html =
      render_component(&CacheDashboardPage.render/1,
        stats: blank_stats(),
        entries: [],
        coverage: [],
        summary: %{total: 19, live: 5, cold: ["ammo.rounds", "chapters.list"]},
        dataset: blank_dataset()
      )

    assert html =~ "5 / 19"
    assert html =~ "ammo.rounds"
  end
end
