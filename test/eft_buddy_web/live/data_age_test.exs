defmodule EftBuddyWeb.DataAgeTest do
  @moduledoc """
  Pages say how old their data is (your decision on audit §9, "data age"):
  "Prices updated 4 min ago" on the Flea Market and Items pages, "Map data
  updated" on Maps, from each feed's last success. The Flea Market's
  description no longer calls its prices "Live".
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  alias EftBuddy.Sync.Reporter
  alias EftBuddyWeb.UI

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  defp succeeded(label) do
    ExUnit.CaptureLog.capture_log(fn -> Reporter.with_run(label, fn -> {:ok, %{}} end) end)
  end

  test "relative wording" do
    now = ~U[2026-10-18 12:00:00Z]

    assert UI.relative_time(~U[2026-10-18 11:59:40Z], now) == "just now"
    assert UI.relative_time(~U[2026-10-18 11:56:00Z], now) == "4 min ago"
    assert UI.relative_time(~U[2026-10-18 09:00:00Z], now) == "3 h ago"
    assert UI.relative_time(~U[2026-10-15 12:00:00Z], now) == "3 d ago"
    # A clock a little ahead of ours is not "in -1 min".
    assert UI.relative_time(~U[2026-10-18 12:00:30Z], now) == "just now"
  end

  # A flea-listable item: it needs a category from one of the page's groups.
  defp flea_item do
    ammo = category(%{name: "Ammo"})
    item(%{name: "7.62x39mm BP", category_id: ammo.id, last_low_price: 412})
  end

  test "the Flea Market says when its prices last updated", %{conn: conn} do
    flea_item()
    succeeded("PricesSync:regular")

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    assert html =~ "Prices updated"
    assert html =~ "just now"
    assert html =~ ~s(phx-hook="RelativeTime")
  end

  test "nothing is claimed for a feed that has not succeeded", %{conn: conn} do
    flea_item()

    {:ok, _view, html} = live(conn, ~p"/flea-market")

    refute html =~ "Prices updated"
  end

  test "Items and Maps carry their own line", %{conn: conn} do
    item(%{name: "Salewa", normalized_name: "salewa"})
    game_map(%{name: "Customs", normalized_name: "customs"})
    succeeded("PricesSync:regular")
    succeeded("MapsSync")

    {:ok, _view, items} = live(conn, ~p"/items")
    {:ok, _view, maps} = live(conn, ~p"/maps")

    assert items =~ "Prices updated"
    assert maps =~ "Map data updated"
  end

  test "the Flea Market no longer calls its prices live", %{conn: conn} do
    html = conn |> get(~p"/flea-market") |> html_response(200)

    [description] =
      Regex.run(~r/<meta name="description" content="([^"]*)"/, html, capture: :all_but_first)

    refute description =~ ~r/\blive\b/i
  end
end
