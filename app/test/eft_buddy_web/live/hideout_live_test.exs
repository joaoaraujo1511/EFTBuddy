defmodule EftBuddyWeb.HideoutLiveTest do
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  # With no stations synced, `LoadState.resolve(@modules != [], :hideout)`
  # (index.html.heex:1) yields `:loading`, so the page renders the shared
  # `<.standby>` panel INSTEAD of the filter tabs — the tabs are gated on
  # `load_state == :loaded` at :17 and standby renders at :60. That is the
  # designed behaviour, so the empty-catalog case asserts standby rather than
  # tabs. Mirrors `ammo_live_test.exs`'s "shows the shared standby state".
  test "shows the shared standby state when no stations are synced", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/hideout")

    assert html =~ "Standby"
    assert html =~ "Data is loading in the background"
    # The chrome that belongs to a loaded page is absent.
    refute html =~ "Maxed"
  end

  test "renders the filter tabs with per-view counts once stations exist", %{conn: conn} do
    # `Hideout.list_modules/0` left-joins station levels, so a station with no
    # levels still yields a module row — enough to flip LoadState to :loaded.
    station()

    {:ok, _view, html} = live(conn, ~p"/hideout")

    # The filter tabs render with their labels…
    assert html =~ "Available"
    assert html =~ "Maxed"
    # …and with a single unbuilt station, the "Maxed" bucket reads 0.
    assert html =~ ~r/text-\[10px\][^>]*>\s*0\s*</
  end

  # `toggle_requirement` builds its storage key by interpolating three
  # client-supplied values and then ACCUMULATES that key into the operator's
  # progress blob, which `EftBuddy.OperatorSession` holds for up to four hours
  # across up to 50,000 sessions. Unvalidated, the tick set was an unbounded set of
  # attacker-chosen strings; a non-string `level` also raised
  # `Protocol.UndefinedError` inside the interpolation and killed the LiveView,
  # which then reconnected into the same push.
  describe "toggle_requirement rejects anything not in this socket's catalogue" do
    setup %{conn: conn} do
      station()
      {:ok, view, _html} = live(conn, ~p"/hideout")
      %{view: view}
    end

    test "an unknown station slug is ignored", %{view: view} do
      assert render_hook(view, "toggle_requirement", %{
               "slug" => "not-a-station",
               "level" => "1",
               "req" => "whatever"
             })

      refute_push_event(view, "eft:store", _payload)
    end

    test "a non-string payload is ignored rather than crashing the LiveView", %{view: view} do
      for level <- [%{"a" => 1}, ["list"], 7, nil] do
        assert render_hook(view, "toggle_requirement", %{
                 "slug" => "workbench",
                 "level" => level,
                 "req" => "whatever"
               })
      end

      # Still alive and still rendering, which is the point.
      assert render(view) =~ "Available"
    end

    test "a missing key is ignored", %{view: view} do
      assert render_hook(view, "toggle_requirement", %{"slug" => "workbench"})
      assert render(view) =~ "Available"
    end
  end
end
