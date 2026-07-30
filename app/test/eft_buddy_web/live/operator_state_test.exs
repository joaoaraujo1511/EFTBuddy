defmodule EftBuddyWeb.OperatorStateTest do
  @moduledoc """
  Regression tests for the operator HUD flashing stale values on live
  navigation.

  ## What the bug was

  Every route shares one `live_session`, so `<.link navigate>` performs client-
  side live navigation: the destination LiveView mounts over the *existing*
  socket, and `on_mount` therefore runs against the socket's **connect-time**
  session - a snapshot frozen when the WebSocket connected, which no later
  cookie write can refresh.

  Operator prefs used to be hydrated from that frozen snapshot, so anything the
  operator changed after connecting was invisible to the next page: the HUD
  rendered the connect-time values, then visibly snapped to the correct ones
  when a client round-trip (`eft:prefs`) corrected it. Progress (watchlists) was
  worse - `localStorage` is never readable server-side, so it always rendered
  empty first.

  ## What these tests pin down

  The tests below mount with a session that deliberately carries **no**
  `eft_prefs` - exactly like a live navigation whose frozen snapshot predates
  the operator's changes - and assert the **first** render is already correct.
  Before the fix these would render defaults (level 1 / USEC / PVP / no
  watchlist) and only reach the right values a round-trip later.
  """
  use EftBuddyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EftBuddy.Operator
  alias EftBuddy.OperatorSessions
  alias EftBuddyWeb.Plugs.OperatorSession, as: SessionPlug

  defp new_token, do: "livetest-#{System.unique_integer([:positive])}"

  # A conn whose session identifies an operator but carries NO prefs cookie -
  # the shape of a live navigation's frozen connect-time session.
  defp conn_for(conn, token) do
    Plug.Test.init_test_session(conn, %{SessionPlug.token_key() => token})
  end

  defp level_field(view), do: view |> element("#pmc-level-hud") |> render()

  describe "first render after a live navigation" do
    test "renders the operator's current PMC level, not the connect-time one", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token)
      assert {:ok, prefs} = OperatorSessions.put_pref(token, :pmc_level, 42)
      assert Operator.get_pref(prefs, :pmc_level) == 42

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      assert level_field(view) =~ ~s(value="42")
      refute level_field(view) =~ ~s(value="1")
    end

    test "renders the current game mode and faction", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token)
      OperatorSessions.put_pref(token, :mode, "pve")
      OperatorSessions.put_pref(token, :faction, "bear")

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      # `aria-pressed={@active}` renders as a boolean attribute, so the active
      # toggle simply *has* the attribute and the inactive one omits it.
      assert has_element?(view, ~s{button[phx-value-mode="pve"][aria-pressed]})
      assert has_element?(view, ~s{button[phx-value-faction="bear"][aria-pressed]})
      refute has_element?(view, ~s{button[phx-value-mode="pvp"][aria-pressed]})
      refute has_element?(view, ~s{button[phx-value-faction="usec"][aria-pressed]})
    end

    test "renders the current scav karma", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token)
      OperatorSessions.put_pref(token, :scav_karma, -2.5)

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      assert view |> element("#scav-karma-input-hud") |> render() =~ ~s(value="-2.5")
    end

    test "renders the collapsed state of the nav rail", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token)
      OperatorSessions.put_pref(token, :rail_collapsed, true)

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      # Collapsed rail swaps in the compact profile summary (an expand button).
      assert has_element?(
               view,
               ~s{button[phx-click="toggle_rail"][aria-label="Expand navigation"]}
             )
    end

    test "renders the operator's watchlist without waiting for a client round-trip",
         %{conn: conn} do
      # This is the second, less-visible half of the same bug: progress lives in
      # localStorage, which the server can never read, so watchlists used to
      # render empty on every navigation and pop in a beat later.
      import EftBuddy.Fixtures, only: [task: 1]

      task(%{name: "Debut", normalized_name: "debut"})

      token = new_token()
      OperatorSessions.snapshot(token)
      OperatorSessions.merge_progress(token, :pvp, %{"tasks_watchlist" => ["debut"]})

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      # The WATCHLIST tab's count pill is derived from the restored slug set, so
      # a count of 1 in the FIRST render proves progress was hydrated in mount.
      assert view |> element(~s{a[href="/tasks?status=watchlist"]}) |> render() =~ ~r/>\s*1\s*</
    end
  end

  describe "HUD interactions persist to the operator session" do
    test "a level change survives into the next page's first render", %{conn: conn} do
      # The end-to-end shape of the original bug report: change a HUD value,
      # navigate, and the new page must already show the new value.
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, tasks_view, _html} = live(conn, ~p"/tasks")

      tasks_view
      |> element(~s{button[phx-click="pmc_level_inc"]})
      |> render_click()

      assert level_field(tasks_view) =~ ~s(value="2")

      # A brand-new mount with the same (pref-less) session, standing in for the
      # live navigation the nav rail performs.
      {:ok, items_view, _html} = live(conn, ~p"/items")

      assert level_field(items_view) =~ ~s(value="2")
    end

    test "an invalid typed level leaves the stored value untouched", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token)
      OperatorSessions.put_pref(token, :pmc_level, 30)

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view
      |> element(~s{form[phx-change="set_pmc_level"]})
      |> render_change(%{"pmc_level" => ""})

      assert stored_level(token) == 30
    end

    test "a typed level is clamped to the legal range", %{conn: conn} do
      token = new_token()
      conn = conn_for(conn, token)
      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> element(~s{form[phx-change="set_pmc_level"]})
      |> render_change(%{"pmc_level" => "9999"})

      assert stored_level(token) == Operator.max_level()
    end
  end

  describe "session identity" do
    test "the plug mints an operator token on a plain request", %{conn: conn} do
      conn = get(conn, ~p"/tasks")

      token = Plug.Conn.get_session(conn, SessionPlug.token_key())
      assert is_binary(token) and byte_size(token) > 0
    end

    test "a first-ever visit renders defaults and is immediately interactive",
         %{conn: conn} do
      # An empty starting session: the plug mints a token, no session process
      # exists yet, so the HUD renders defaults and creates one on first use.
      # (The `nil`-token fallback itself is unit-tested in
      # `EftBuddy.OperatorSessionsTest`, since the pipeline always mints one.)
      {:ok, view, _html} = live(Plug.Test.init_test_session(conn, %{}), ~p"/tasks")

      assert level_field(view) =~ ~s(value="1")

      view |> element(~s{button[phx-click="pmc_level_inc"]}) |> render_click()

      assert level_field(view) =~ ~s(value="2")
    end

    test "a cold boot seeds the session from the prefs cookie", %{conn: conn} do
      # Set the real cookie the browser writes, rather than pre-seeding the
      # session: the plug deliberately DROPS a bridged session copy when the
      # cookie is absent, so that a client-side reset can't be undone by stale
      # session data.
      prefs =
        URI.encode(
          Jason.encode!(%{"modes" => %{"pvp" => %{"pmc_level" => 33, "faction" => "bear"}}})
        )

      {:ok, view, _html} =
        conn
        |> Plug.Test.put_req_cookie(SessionPlug.prefs_key(), prefs)
        |> live(~p"/tasks")

      assert level_field(view) =~ ~s(value="33")
      assert has_element?(view, ~s{button[phx-value-faction="bear"][aria-pressed]})
    end

    test "a missing prefs cookie clears a previously bridged copy from the session",
         %{conn: conn} do
      # Guards the "Reset progress" path: the client deletes the cookie, so the
      # server must not keep re-hydrating the old values from the session.
      conn =
        Plug.Test.init_test_session(conn, %{SessionPlug.prefs_key() => %{"pmc_level" => 70}})

      conn = get(conn, ~p"/tasks")

      assert Plug.Conn.get_session(conn, SessionPlug.prefs_key()) == nil
    end
  end

  describe "per-mode profiles" do
    test "flipping mode swaps level, karma and faction to that mode's profile",
         %{conn: conn} do
      # PVP and PVE are separate progressions in-game. Before this, the HUD kept
      # one shared level/karma/faction and only the DB-derived views (tasks, flea
      # prices) reacted to the toggle - so the profile block claimed the operator
      # was level 42 in a mode they had never played.
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      view
      |> element(~s{form[phx-change="set_pmc_level"]})
      |> render_change(%{"pmc_level" => "42"})

      view
      |> element(~s{button[phx-click="set_faction"][phx-value-faction="bear"]})
      |> render_click()

      assert level_field(view) =~ ~s(value="42")

      # Into PVE: a fresh profile, at defaults.
      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pve"]}) |> render_click()

      assert level_field(view) =~ ~s(value="1")
      assert has_element?(view, ~s{button[phx-value-faction="usec"][aria-pressed]})

      view
      |> element(~s{form[phx-change="set_pmc_level"]})
      |> render_change(%{"pmc_level" => "7"})

      # ...and back to PVP finds the original profile exactly as it was left.
      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pvp"]}) |> render_click()

      assert level_field(view) =~ ~s(value="42")
      assert has_element?(view, ~s{button[phx-value-faction="bear"][aria-pressed]})

      prefs = OperatorSessions.snapshot(token).prefs
      assert Operator.mode_slice(prefs, :pvp).pmc_level == 42
      assert Operator.mode_slice(prefs, :pve).pmc_level == 7
    end

    test "a per-mode profile survives into the next page's first render", %{conn: conn} do
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pve"]}) |> render_click()

      view
      |> element(~s{form[phx-change="set_pmc_level"]})
      |> render_change(%{"pmc_level" => "18"})

      {:ok, items_view, _html} = live(conn, ~p"/items")

      assert level_field(items_view) =~ ~s(value="18")
    end

    test "the watchlist is per mode too", %{conn: conn} do
      import EftBuddy.Fixtures, only: [task: 1]

      # The same quest in both quest graphs, so neither board is empty (an empty
      # board renders the standby panel instead of the options bar).
      task(%{name: "Debut", normalized_name: "debut", game_mode: "regular"})
      task(%{name: "Debut", normalized_name: "debut", game_mode: "pve"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view
      |> element(~s{button[aria-label="Toggle watchlist for Debut"]})
      |> render_click()

      assert watchlist_count(view) =~ ~r/>\s*1\s*</

      # Watchlisting a quest in PVP must not put it on the PVE backlog: the two
      # modes are separate playthroughs, usually at different stages.
      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pve"]}) |> render_click()

      assert watchlist_count(view) =~ ~r/>\s*0\s*</

      # ...and coming back finds it still there.
      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pvp"]}) |> render_click()

      assert watchlist_count(view) =~ ~r/>\s*1\s*</
    end

    test "completed quests are per mode", %{conn: conn} do
      import EftBuddy.Fixtures, only: [task: 1]

      task(%{name: "Debut", normalized_name: "debut", game_mode: "regular"})
      task(%{name: "Debut", normalized_name: "debut", game_mode: "pve"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view
      |> element(~s{button[aria-label="Mark Debut complete"]})
      |> render_click()

      assert completed_count(view) =~ ~r/>\s*1\s*</

      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pve"]}) |> render_click()
      assert completed_count(view) =~ ~r/>\s*0\s*</
    end

    test "the nav rail's collapsed state is shared, not per mode", %{conn: conn} do
      # Pure chrome: it describes the browser, not the character.
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view |> element(~s{button[phx-click="toggle_rail"]}) |> render_click()
      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pve"]}) |> render_click()

      assert Operator.get_pref(OperatorSessions.snapshot(token).prefs, :rail_collapsed) == true
    end
  end

  defp stored_level(token) do
    Operator.get_pref(OperatorSessions.snapshot(token).prefs, :pmc_level)
  end

  defp watchlist_count(view) do
    view |> element(~s{a[href="/tasks?status=watchlist"]}) |> render()
  end

  defp completed_count(view) do
    view |> element(~s{a[href="/tasks?status=completed"]}) |> render()
  end
end
