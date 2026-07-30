defmodule EftBuddyWeb.ClientBridgeTest do
  @moduledoc """
  Tests for the browser <-> server transport for operator state: cold-boot
  hydration of the `localStorage` progress blob, the reset/import flow, and
  graceful degradation when the authoritative session is gone.
  """
  use EftBuddyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures, only: [task: 1]

  alias EftBuddy.Operator
  alias EftBuddy.OperatorSessions
  alias EftBuddy.Progress
  alias EftBuddyWeb.Plugs.OperatorSession, as: SessionPlug

  defp new_token, do: "bridge-#{System.unique_integer([:positive])}"

  defp conn_for(conn, token) do
    Plug.Test.init_test_session(conn, %{SessionPlug.token_key() => token})
  end

  # The Tasks WATCHLIST tab's count pill, which is derived from the progress blob.
  defp watchlist_tab(view) do
    view |> element(~s{a[href="/tasks?status=watchlist"]}) |> render()
  end

  # The per-row star. It pushes via `JS.push(..., value: %{slug: ...})`, so there
  # is no `phx-value-slug` attribute to select on.
  defp toggle_watchlist(view, task_name) do
    view
    |> element(~s{button[aria-label="Toggle watchlist for #{task_name}"]})
    |> render_click()
  end

  describe "eft:restore (cold boot)" do
    test "seeds the session from localStorage and reflows the page", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      # Nothing watchlisted before the browser speaks up.
      assert watchlist_tab(view) =~ ~r/>\s*0\s*</

      render_hook(view, "eft:restore", pvp_blob(%{"tasks_watchlist" => ["debut"]}))

      assert watchlist_tab(view) =~ ~r/>\s*1\s*</
      assert watchlisted(token, :pvp) == ["debut"]
    end

    test "a blob for the OTHER mode does not leak into this one", %{conn: conn} do
      # Progress is per game mode, so a PVE watchlist must not paint stars on the
      # PVP board the operator is currently looking at.
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      render_hook(view, "eft:restore", %{
        "modes" => %{"pve" => %{"tasks_watchlist" => ["debut"]}}
      })

      # Default mode is PVP, so nothing is marked here...
      assert watchlist_tab(view) =~ ~r/>\s*0\s*</
      # ...but the PVE slice was still taken up.
      assert watchlisted(token, :pve) == ["debut"]
    end

    test "a later restore cannot clobber progress already in the session", %{conn: conn} do
      # A second tab connecting must not roll back work done since the first
      # tab seeded, so seeding is once-only.
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")
      render_hook(view, "eft:restore", pvp_blob(%{"tasks_watchlist" => ["debut"]}))
      render_hook(view, "eft:restore", pvp_blob(%{"tasks_watchlist" => []}))

      assert watchlist_tab(view) =~ ~r/>\s*1\s*</
      assert watchlisted(token, :pvp) == ["debut"]
    end

    test "an empty blob from a first-time visitor is harmless", %{conn: conn} do
      token = new_token()
      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      render_hook(view, "eft:restore", %{})

      assert %{progress: progress, progress_seeded?: true} = OperatorSessions.snapshot(token)
      assert progress == Progress.empty()
      assert render(view) =~ "Tasks"
    end
  end

  describe "progress writes" do
    test "a watchlist toggle lands in the authoritative session", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      toggle_watchlist(view, "Debut")

      # In the ACTIVE mode's slice, and only there.
      assert watchlisted(token, :pvp) == ["debut"]
      assert Progress.slice(progress(token), :pve) == %{}
    end

    test "a progress write survives into the next page's first render", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      toggle_watchlist(view, "Debut")

      # A fresh mount standing in for a live navigation: the watchlist must
      # already be reflected, with no client round-trip.
      {:ok, next_view, _html} = live(conn, ~p"/tasks")

      assert watchlist_tab(next_view) =~ ~r/>\s*1\s*</
    end
  end

  describe "reset / import" do
    test "the reset route returns the session to defaults", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.put_pref(token, :pmc_level, 55)
      OperatorSessions.merge_progress(token, :pvp, %{"tasks_watchlist" => ["debut"]})

      conn = conn_for(conn, token) |> post(~p"/session/reset")

      assert redirected_to(conn) == "/tasks"
      assert %{prefs: prefs, progress: progress} = OperatorSessions.snapshot(token)
      assert prefs == Operator.defaults()
      assert progress == Progress.empty()
    end

    test "the reset route rotates the operator token", %{conn: conn} do
      # Rotation is what makes IMPORT work: an existing session ignores seed
      # prefs by design, so the reloading tab needs a brand-new one to pick up
      # the freshly written cookie.
      token = new_token()

      conn = conn_for(conn, token) |> post(~p"/session/reset")

      assert Plug.Conn.get_session(conn, SessionPlug.token_key()) != token
    end

    test "after reset+rotation the next page seeds from the newly written cookie",
         %{conn: conn} do
      # End-to-end shape of an import: storage rewritten client-side, then a
      # navigation through the reset route.
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.put_pref(token, :pmc_level, 55)

      imported =
        URI.encode(Jason.encode!(%{"modes" => %{"pvp" => %{"pmc_level" => 12}}}))

      conn =
        conn_for(conn, token)
        |> Plug.Test.put_req_cookie(SessionPlug.prefs_key(), imported)
        |> post(~p"/session/reset")

      {:ok, view, _html} = live(conn, ~p"/tasks")

      # 12 (imported), NOT 55 (the pre-import session's value).
      assert view |> element("#pmc-level-hud") |> render() =~ ~s(value="12")
    end

    # SECURITY REGRESSION: this route used to be a GET. It discards progress and
    # rotates the operator token, and its broadcast empties `:client_state` in the
    # operator's other open tabs - whose next write then pushes that empty blob
    # over `localStorage`, the only durable copy of their progress. Because
    # `same_site: "Lax"` still sends the session cookie on a cross-site top-level
    # navigation, a single posted link was enough to destroy a visitor's tracker.
    # `:protect_from_forgery` only validates non-idempotent methods, so the route
    # being POST-only is what actually protects it. Do not reintroduce a GET.
    test "the reset route refuses a cross-site GET", %{conn: conn} do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.merge_progress(token, :pvp, %{"tasks_watchlist" => ["debut"]})

      # No route matches GET, so the request 404s before reaching the controller.
      assert conn_for(conn, token) |> get("/session/reset") |> response(404)

      # And crucially the session is untouched - the reset did not happen.
      assert watchlisted(token, :pvp) == ["debut"]
    end

    # REGRESSION, and it was self-inflicted. When `eft:store` became a per-mode MERGE
    # (so a resurrected empty session can no longer destroy localStorage), a reset
    # needed some way to say "actually do remove keys" — so this broadcast pushed
    # `eft:clear`. That broke IMPORT: `Backup.import` writes the imported blob to
    # localStorage and THEN navigates through this same reset route, so the push
    # deleted the file the operator had just restored and the reload cold-seeded from
    # empty storage. Import silently did nothing except erase the device.
    #
    # The tests around it all passed, because they POST through `conn` with no
    # LiveView subscribed to the operator topic — so nothing ever received the
    # broadcast. This one subscribes a real socket first, which is the arrangement
    # that exposes it.
    test "a reset must not push a wipe to the operator's other tabs", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")
      render_hook(view, "eft:restore", pvp_blob(%{"tasks_watchlist" => ["debut"]}))

      # Another tab (or this one, mid-navigation) triggers reset/import.
      build_conn() |> conn_for(token) |> post(~p"/session/reset")

      # Force the broadcast to be processed before asserting.
      assert render(view)

      refute_push_event(view, "eft:clear", _payload)
    end

    test "after a reset the surviving tab's next write cannot destroy imported storage",
         %{conn: conn} do
      # The other half: the surviving tab's `:client_state` is emptied by the reset,
      # so its next write pushes a patch-only blob. That is SAFE only because the
      # browser merges per mode — and it must still push, or an import in another tab
      # would leave this one unable to persist anything.
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")
      render_hook(view, "eft:restore", pvp_blob(%{"completed_tasks" => ["shortage"]}))

      build_conn() |> conn_for(token) |> post(~p"/session/reset")
      assert render(view)

      toggle_watchlist(view, "Debut")

      # It still pushes (the tab is not left inert)...
      assert_push_event(view, "eft:store", pushed)
      # ...and what it pushes carries only this write, which the client merges into
      # whatever storage now holds rather than replacing it.
      assert Progress.slice(pushed, :pvp)["tasks_watchlist"] == ["debut"]
    end

    test "the reset response is not cacheable", %{conn: conn} do
      # A request with side effects: a cached response would skip both the reset
      # and the token rotation that makes import work.
      conn = conn_for(conn, new_token()) |> post(~p"/session/reset")

      assert conn |> Plug.Conn.get_resp_header("cache-control") |> List.first() =~ "no-store"
    end

    test "return_to only ever bounces back to an in-app path", %{conn: conn} do
      # The last two are the interesting ones: both start with a single `/`, so a
      # "leading slash and not a double slash" check admits them - and then
      # `Phoenix.Controller.redirect/2` REJECTS them by raising (its
      # `@invalid_local_url_chars` are `\`, `/%09` and `/\t`), turning a
      # user-supplied string into a 500. The guard has to be an allow-list.
      for hostile <- [
            "//evil.example.com",
            "https://evil.example.com",
            "javascript:alert(1)",
            "/\\evil.example",
            "/%09/evil.example"
          ] do
        conn =
          build_conn()
          |> conn_for(new_token())
          |> post(~p"/session/reset", %{"return_to" => hostile})

        assert redirected_to(conn) == "/tasks"
      end

      conn = conn_for(conn, new_token()) |> post(~p"/session/reset", %{"return_to" => "/items"})
      assert redirected_to(conn) == "/items"

      # A real in-app path with a query string still has to survive - this is what
      # the Backup menu actually sends, since it returns you to the page you were
      # on (`window.location.pathname + search`).
      conn =
        build_conn()
        |> conn_for(new_token())
        |> post(~p"/session/reset", %{"return_to" => "/tasks?status=watchlist"})

      assert redirected_to(conn) == "/tasks?status=watchlist"
    end
  end

  describe "clients running pre-deploy JavaScript" do
    test "an obsolete eft:* push is ignored instead of crashing the LiveView", %{conn: conn} do
      # A tab open across a deploy still runs the OLD app.js and will push events
      # this version removed (`eft:prefs`, `eft:reset`). Without a tolerant
      # clause these fall through to the page, whose handle_event/3 has no
      # matching clause, and the LiveView crash-loops - it reconnects with the
      # same stale JS and pushes again - until the visitor hard-reloads.
      {:ok, view, _html} = live(conn_for(conn, new_token()), ~p"/tasks")

      for legacy <- ["eft:prefs", "eft:reset", "eft:something-future"] do
        assert render_hook(view, legacy, %{"pmc_level" => 40})
      end

      # Still alive, still rendering, and the stale payload changed nothing.
      assert view |> element("#pmc-level-hud") |> render() =~ ~s(value="1")
    end
  end

  describe "degradation when the session is gone" do
    test "a HUD control still works after the session has shut down", %{conn: conn} do
      # An idle timeout must never leave the HUD silently inert.
      token = new_token()
      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view |> element(~s{button[phx-click="pmc_level_inc"]}) |> render_click()
      assert view |> element("#pmc-level-hud") |> render() =~ ~s(value="2")

      # Kill the session out from under the live view.
      kill_session(token)

      # The control still responds, and the write restarts the session carrying
      # the state that was on screen rather than bare defaults.
      view |> element(~s{button[phx-click="pmc_level_inc"]}) |> render_click()

      assert view |> element("#pmc-level-hud") |> render() =~ ~s(value="3")
      assert Operator.get_pref(prefs(token), :pmc_level) == 3
    end

    # REGRESSION: a write against a session that died (idle timeout, crash, or
    # `restart: :temporary` after any exit) used to merge the patch into a FRESH,
    # EMPTY blob and push that result to the browser, where `eft:store` REPLACES
    # localStorage wholesale. Since the browser holds the only durable copy of a
    # player's progress, that silently destroyed all of it. The write path must
    # therefore seed a resurrected session from what this socket still knows.
    test "progress survives a write that revives a dead session", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      task(%{name: "Shortage", normalized_name: "shortage"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      # Two independent keys, so we can prove the untouched one is not lost.
      render_hook(
        view,
        "eft:restore",
        pvp_blob(%{"tasks_watchlist" => ["debut"], "completed_tasks" => ["shortage"]})
      )

      assert watchlisted(token, :pvp) == ["debut"]

      kill_session(token)

      # This write revives the session. It must not erase the rest of the blob.
      toggle_watchlist(view, "Shortage")

      slice = Progress.slice(progress(token), :pvp)

      assert slice["tasks_watchlist"] == ["debut", "shortage"] or
               slice["tasks_watchlist"] == ["shortage", "debut"]

      # The key this write never touched must still be there.
      assert slice["completed_tasks"] == ["shortage"]
    end

    test "other prefs are not reset when a write revives a dead session", %{conn: conn} do
      token = new_token()
      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view
      |> element(~s{button[phx-click="set_faction"][phx-value-faction="bear"]})
      |> render_click()

      kill_session(token)

      # Changing an unrelated pref must not silently drop the faction.
      view |> element(~s{button[phx-click="pmc_level_inc"]}) |> render_click()

      assert Operator.active(prefs(token)) |> Map.take([:faction, :pmc_level]) ==
               %{faction: :bear, pmc_level: 2}
    end

    # REGRESSION. The three tests below are the PROGRESS-write half of the test
    # directly above, and for a long time only the pref half existed.
    #
    # `OperatorSessions` states the contract in its own moduledoc: *"Callers pass
    # `:seed_prefs` on a write so a resurrected session comes back with the state
    # the operator can currently see, rather than bare defaults."* `OperatorState`
    # honoured it; both `ClientBridge` call sites did not — so a write that
    # revived a session rebuilt it from `Operator.parse_all(%{})`, i.e. defaults.
    #
    # Nothing was visible at the moment of damage: the writing tab's assigns are
    # untouched, so it kept rendering the operator's real prefs. The loss landed on
    # the NEXT mount, which reads the (now live) session, wins over the socket, and
    # pushes those defaults over the `eft_prefs` cookie — the durable copy.
    test "prefs are not reset when a PROGRESS write revives a dead session", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view
      |> element(~s{button[phx-click="set_faction"][phx-value-faction="bear"]})
      |> render_click()

      kill_session(token)

      # A progress write, not a pref write. Same revival, same obligation.
      toggle_watchlist(view, "Debut")

      assert Operator.active(prefs(token)).faction == :bear
    end

    # The consequence with teeth. Reverting `:mode` does not merely mis-draw the
    # HUD - progress is namespaced per game mode, so the operator's next session
    # reads and writes the OTHER mode's slice. Their PVE board comes back empty
    # and their next completions accumulate somewhere they cannot see.
    test "the active game mode survives, so later writes stay in the right slice",
         %{conn: conn} do
      # Seeded in BOTH modes deliberately. With PVE-only rows a reverted mode
      # would fail this test by rendering an empty board - i.e. in the setup,
      # before reaching the assertion that actually describes the defect.
      for mode <- ["regular", "pve"] do
        task(%{name: "Debut", normalized_name: "debut", game_mode: mode})
        task(%{name: "Shortage", normalized_name: "shortage", game_mode: mode})
      end

      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view |> element(~s{button[phx-click="set_mode"][phx-value-mode="pve"]}) |> render_click()

      kill_session(token)

      # This write revives the session. It uses the socket's own `:mode`, so it
      # still lands in PVE - the damage is to what the session comes back holding.
      toggle_watchlist(view, "Debut")

      assert prefs(token).mode == :pve

      # The mount that surfaces it. A fresh LiveView on the same token finds the
      # session alive and takes its prefs as authoritative.
      {:ok, next, _html} = live(conn_for(conn, token), ~p"/tasks")
      toggle_watchlist(next, "Shortage")

      assert watchlisted(token, :pve) == ["debut", "shortage"] or
               watchlisted(token, :pve) == ["shortage", "debut"]

      refute "shortage" in (watchlisted(token, :pvp) || [])
    end

    # The second, quieter call site: `eft:restore` passed no opts at all.
    test "prefs are not reset when eft:restore revives a dead session", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()

      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      view
      |> element(~s{button[phx-click="set_faction"][phx-value-faction="bear"]})
      |> render_click()

      kill_session(token)

      render_hook(view, "eft:restore", pvp_blob(%{"tasks_watchlist" => ["debut"]}))

      assert Operator.active(prefs(token)).faction == :bear
    end
  end

  # A socket REJOIN is not a page load. LiveView patches the existing DOM and
  # calls `reconnected()` on already-registered hooks; `mounted()` fires only for
  # nodes the join patch reports as newly added. So on a rejoin the `Hud` hook's
  # `mounted()` - and therefore its one `eft:restore` push - does NOT re-run.
  #
  # That matters because a rejoin is exactly when the session is most likely to be
  # gone: a >4h-idle tab, a crash (`restart: :temporary`), or a deploy, which kills
  # every session at once while every open tab quietly rejoins. `on_mount` then
  # creates a fresh EMPTY session and assigns its empty blob to `:client_state` -
  # the very value `put_progress/2` uses as its floor.
  #
  # `LiveViewTest` reproduces a rejoin exactly: a second `live/2` on the same token
  # with no `eft:restore` hook. (A live *navigation* is different and heals itself,
  # because `replaceMain` clones the container empty and every node is new.)
  describe "a rejoin whose session died" do
    test "does not push a blob poorer than the browser's", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      task(%{name: "Shortage", normalized_name: "shortage"})
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, view, _html} = live(conn, ~p"/tasks")

      render_hook(
        view,
        "eft:restore",
        pvp_blob(%{"tasks_watchlist" => ["debut"], "completed_tasks" => ["shortage"]})
      )

      kill_session(token)

      # The rejoin. No restore push, so nothing tells the server what the browser
      # holds and `:client_state` starts empty.
      {:ok, rejoined, _html} = live(conn, ~p"/tasks")

      toggle_watchlist(rejoined, "Debut")

      # `eft:store` is the only writer of localStorage, so a push computed from an
      # empty floor is the whole data-loss bug. While the browser has not spoken to
      # THIS socket we must not push at all: dropping one write is recoverable,
      # overwriting the only durable copy is not.
      refute_push_event(rejoined, "eft:store", _payload)
    end

    test "recovers the full blob once the reconnect push lands", %{conn: conn} do
      # The other half of the fix: the hook re-pushes `eft:restore` on
      # `reconnected()`, so the window above is milliseconds wide and the socket
      # then behaves normally.
      task(%{name: "Debut", normalized_name: "debut"})
      task(%{name: "Shortage", normalized_name: "shortage"})
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      stored = pvp_blob(%{"tasks_watchlist" => ["debut"], "completed_tasks" => ["shortage"]})
      render_hook(view, "eft:restore", stored)

      kill_session(token)

      {:ok, rejoined, _html} = live(conn, ~p"/tasks")

      # What `reconnected()` does. The browser's blob is unchanged - it was never
      # overwritten - so this is the same payload it handed up the first time.
      render_hook(rejoined, "eft:restore", stored)

      toggle_watchlist(rejoined, "Shortage")

      assert_push_event(rejoined, "eft:store", pushed)
      slice = Progress.slice(pushed, :pvp)

      # The untouched key survived, and the touched one grew rather than replaced.
      assert slice["completed_tasks"] == ["shortage"]
      assert Enum.sort(slice["tasks_watchlist"]) == ["debut", "shortage"]
    end

    test "still records the write in the session itself", %{conn: conn} do
      # Suppressing the PUSH must not suppress the WRITE. The operator's click has
      # to take effect on screen and in the authority; it is only the durable copy
      # we decline to rewrite until we know what it contains.
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()
      conn = conn_for(conn, token)

      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_hook(view, "eft:restore", pvp_blob(%{"completed_tasks" => ["shortage"]}))
      kill_session(token)

      {:ok, rejoined, _html} = live(conn, ~p"/tasks")
      toggle_watchlist(rejoined, "Debut")

      assert watchlist_tab(rejoined) =~ ~r/>\s*1\s*</
      assert watchlisted(token, :pvp) == ["debut"]
    end
  end

  describe "cross-tab convergence" do
    test "a pref changed in another tab is applied to this one", %{conn: conn} do
      token = new_token()
      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      # Mutate from an unrelated process, i.e. the operator's other tab.
      spawn_and_await(fn -> OperatorSessions.put_pref(token, :pmc_level, 64) end)

      assert render(view)
      assert view |> element("#pmc-level-hud") |> render() =~ ~s(value="64")
    end

    test "progress changed in another tab reflows this one", %{conn: conn} do
      task(%{name: "Debut", normalized_name: "debut"})
      token = new_token()
      {:ok, view, _html} = live(conn_for(conn, token), ~p"/tasks")

      spawn_and_await(fn ->
        OperatorSessions.merge_progress(token, :pvp, %{"tasks_watchlist" => ["debut"]})
      end)

      assert render(view)
      assert watchlist_tab(view) =~ ~r/>\s*1\s*</
    end
  end

  # Kill an operator's session out from under the LiveViews attached to it, and
  # wait for the exit so the next call genuinely finds nothing. `restart:
  # :temporary` means it is not replaced.
  defp kill_session(token) do
    [{pid, _value}] = Registry.lookup(EftBuddy.OperatorSessions.Registry, token)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp progress(token), do: OperatorSessions.snapshot(token).progress
  defp prefs(token), do: OperatorSessions.snapshot(token).prefs
  defp watchlisted(token, mode), do: Progress.get(progress(token), mode, "tasks_watchlist")

  # A localStorage blob carrying `slice` as the PVP mode's slice.
  defp pvp_blob(slice), do: %{"modes" => %{"pvp" => slice}}

  defp spawn_and_await(fun) do
    test = self()

    spawn(fn ->
      fun.()
      send(test, :done)
    end)

    assert_receive :done
  end
end
