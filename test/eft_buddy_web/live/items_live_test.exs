defmodule EftBuddyWeb.ItemsLiveTest do
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  test "renders the scope tabs with live counts and lists items", %{conn: conn} do
    cat = category()
    item(%{name: "Salewa First Aid Kit", category_id: cat.id, last_low_price: 25_000})

    {:ok, _view, html} = live(conn, ~p"/items")

    # Scope tabs render their labels with count badges reflecting the
    # catalog (one regular item → All count of 1).
    assert html =~ "Hideout"
    assert html =~ ~r/text-\[10px\][^>]*>\s*1\s*</
    # The seeded item is listed.
    assert html =~ "Salewa First Aid Kit"
  end

  test "search narrows the listing via a URL patch", %{conn: conn} do
    cat = category()
    item(%{name: "Salewa", category_id: cat.id})
    item(%{name: "Morphine", category_id: cat.id})

    {:ok, view, _html} = live(conn, ~p"/items")

    html =
      view
      |> form("form[phx-change=\"search\"]", %{"query" => "Salewa"})
      |> render_change()

    assert html =~ "Salewa"
    refute html =~ "Morphine"
  end

  test "an unknown scope falls back to :all", %{conn: conn} do
    # Seed an item so the controls render at all: with an empty catalog
    # `LoadState.resolve/2` yields :loading and the page shows the standby
    # panel instead of the scope tabs.
    cat = category()
    item(%{name: "Salewa First Aid Kit", category_id: cat.id})

    {:ok, view, _html} = live(conn, ~p"/items?scope=bogus")

    # `UI.tabs` marks the active tab with `aria-current="page"` (the category
    # chips below use "true", so this selector picks out the scope row only).
    # Asserting on the attribute rather than a label string keeps this test
    # about the :all FALLBACK rather than about the tab's wording.
    assert has_element?(view, ~s(a[aria-current="page"] span), "All")
  end

  # NOTE: two tests were removed here — "expanding an item shows its flea price
  # section and history graph" and "a quest item (no economy) shows no flea price
  # section". The price panel no longer exists on the Items page: neither
  # `items_live.ex` nor `index.html.heex` contains any price markup, and the ten
  # expanded-row sections are all recipe/quest/hideout ones. The feature lives on
  # the Flea Market page, where it IS covered —
  # `flea_market_live_test.exs:32` (flea low + 24h change) and `:63` (the
  # `<polyline>` history sparkline). The first test therefore failed, and the
  # second passed VACUOUSLY (a `refute` on a string that can never appear), which
  # is a worse signal than no test at all.
  #
  # `UI.price_sparkline/1`'s moduledoc still claims it is "Shared by the Flea
  # Market cards and the Items detail panel" (`ui.ex:833`) — that comment is now
  # wrong and is tracked as documentation drift.
end
