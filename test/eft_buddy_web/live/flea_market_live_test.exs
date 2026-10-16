defmodule EftBuddyWeb.FleaMarketLiveTest do
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query
  import EftBuddy.Fixtures

  alias EftBuddy.Repo
  alias EftBuddy.Items.ItemPrice

  test "lists flea-eligible items and renders category filter chips", %{conn: conn} do
    ammo = category(%{name: "Ammo"})
    item(%{name: "7.62x39mm BP", category_id: ammo.id, last_low_price: 412})

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    # The category filter chips render with their labels (filter bars no
    # longer carry count badges) and the flea-eligible item is listed.
    assert html =~ "Ammo"
    assert html =~ "7.62x39mm BP"
  end

  test "items without a flea price are not listed", %{conn: conn} do
    cat = category()
    item(%{name: "Bolts", category_id: cat.id, last_low_price: nil})

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    refute html =~ "Bolts"
  end

  test "card shows the flea low and upstream's 48h price change", %{conn: conn} do
    cat = category(%{name: "Medikit"})

    item(%{
      name: "Salewa",
      category_id: cat.id,
      last_low_price: 3_000,
      avg_24h_price: 3_450,
      change_last_48h_percent: -13.04
    })

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    assert html =~ "Salewa"
    # The card leads with the last-low "Flea Low" price, thousands-separated.
    assert html =~ "Flea Low"
    assert html =~ "3,000"
    # The right-hand metric is tarkov.dev's own 48h change, rounded to one
    # decimal. It used to be a "24h" figure computed from our own history.
    assert html =~ "48h"
    assert html =~ "-13.0%"
  end

  test "item cards are static and do not link back to the items page", %{conn: conn} do
    cat = category(%{name: "Mechanical Key"})
    item(%{name: "Dorm room 114 key", category_id: cat.id, last_low_price: 60_000})

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    # The item still renders on a card…
    assert html =~ "Dorm room 114 key"
    # …but the round-2 refinement made the cards static: the old
    # click-through link to the items page was removed.
    refute html =~ "/items?q=Dorm"
  end

  test "renders a price-history sparkline when history is present", %{conn: conn} do
    cat = category(%{name: "Pistol grip"})

    it =
      item(%{name: "MOE grip", category_id: cat.id, last_low_price: 4_200})

    Repo.update_all(
      from(p in ItemPrice, where: p.item_id == ^it.id and p.game_mode == "regular"),
      set: [
        historical_prices: [
          %{"price" => 4_000, "timestamp" => 1},
          %{"price" => 4_600, "timestamp" => 2},
          %{"price" => 4_200, "timestamp" => 3}
        ]
      ]
    )

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    assert html =~ "<polyline"
  end

  describe "flea-market lock badge" do
    test "below the unlock floor, a buyable-by-API item is shown locked", %{conn: conn} do
      # tarkov.dev reports minLevelForFlea 0 for this item, but the flea
      # market itself unlocks at 15 — so at the default PMC level (1) it
      # must render the lock badge, not as buyable.
      cat = category(%{name: "Pistol grip", min_level_for_flea_market: nil})
      item(%{name: "MOE grip", category_id: cat.id, last_low_price: 4_200, min_level_for_flea: 0})

      {:ok, _view, html} = live(conn, ~p"/flea-market")

      assert html =~ "MOE grip"
      # Lock badge shows the effective (floored) level, 15.
      assert html =~ "Lvl 15"
      assert html =~ "hero-lock-closed"
    end

    test "a premium item shows its higher per-item level on the badge", %{conn: conn} do
      cat = category(%{name: "Assault rifle", min_level_for_flea_market: nil})

      item(%{
        name: "Colt M4A1",
        category_id: cat.id,
        last_low_price: 40_000,
        min_level_for_flea: 25
      })

      {:ok, _view, html} = live(conn, ~p"/flea-market")

      assert html =~ "Colt M4A1"
      assert html =~ "Lvl 25"
    end
  end
end
