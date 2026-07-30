defmodule EftBuddy.OperatorSessionsTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Operator
  alias EftBuddy.OperatorSessions
  alias EftBuddy.Progress

  # Prefs are nested per game mode, so a test that only cares about "the value
  # the operator currently sees" goes through `active/1` rather than reaching
  # into a slice.
  defp level(prefs), do: Operator.get_pref(prefs, :pmc_level)

  # Unique per test so sessions (which outlive a test by design) never leak
  # state between them.
  defp new_token, do: "test-#{System.unique_integer([:positive])}"

  describe "snapshot/2" do
    test "starts a session on demand, cold-seeded from the prefs cookie" do
      token = new_token()
      refute OperatorSessions.alive?(token)

      %{prefs: prefs} =
        OperatorSessions.snapshot(token,
          seed_prefs: %{"mode" => "pve", "modes" => %{"pve" => %{"pmc_level" => 25}}},
          create: true
        )

      assert OperatorSessions.alive?(token)
      assert prefs.mode == :pve
      assert level(prefs) == 25
      # Unseeded keys fall back to defaults.
      assert Operator.get_pref(prefs, :faction) == :usec
      # ...and the mode the cookie didn't mention keeps its own defaults.
      assert Operator.mode_slice(prefs, :pvp) == Operator.mode_slice(Operator.defaults(), :pvp)
    end

    test "an existing session is authoritative and is NOT re-seeded" do
      # This is the regression at the heart of the HUD flash: a later mount
      # carries a STALE connect-time cookie snapshot, and must never be allowed
      # to overwrite what the operator has since changed.
      token = new_token()
      stale = %{"modes" => %{"pvp" => %{"pmc_level" => 5}}}
      OperatorSessions.snapshot(token, seed_prefs: stale, create: true)
      OperatorSessions.put_pref(token, :pmc_level, 60)

      %{prefs: prefs} = OperatorSessions.snapshot(token, seed_prefs: stale, create: true)

      assert level(prefs) == 60
    end

    test "does not allocate a session unless asked to" do
      # Sessions are only created from a *connected* mount. A static render (or a
      # crawler GET) reads the cookie instead, so it must allocate nothing.
      token = new_token()

      %{prefs: prefs} =
        OperatorSessions.snapshot(token,
          seed_prefs: %{"modes" => %{"pvp" => %{"pmc_level" => 25}}}
        )

      refute OperatorSessions.alive?(token)
      assert level(prefs) == 25
    end

    test "reads an existing session even when not allowed to create one" do
      # A reload's static render should still see the live values.
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.put_pref(token, :pmc_level, 44)

      assert %{prefs: prefs} = OperatorSessions.snapshot(token)
      assert level(prefs) == 44
    end

    test "degrades to cookie-seeded defaults when there is no token" do
      %{prefs: prefs, progress: progress, progress_seeded?: seeded?} =
        OperatorSessions.snapshot(nil, seed_prefs: %{"modes" => %{"pvp" => %{"pmc_level" => 9}}})

      assert level(prefs) == 9
      assert progress == Progress.empty()
      refute seeded?
    end
  end

  describe "put_pref/4" do
    test "stores the canonical value and reports unchanged for no-ops" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      # The whole pref set comes back, not just the one value: a `:mode` change
      # swaps the active slice, so level / karma / faction move with it.
      assert {:ok, %{mode: :pve}} = OperatorSessions.put_pref(token, :mode, "pve")
      assert :unchanged = OperatorSessions.put_pref(token, :mode, "pve")
      assert %{prefs: %{mode: :pve}} = OperatorSessions.snapshot(token)
    end

    test "rejects invalid values without disturbing stored state" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.put_pref(token, :pmc_level, 40)

      assert :unchanged = OperatorSessions.put_pref(token, :pmc_level, "not-a-level")
      assert :unchanged = OperatorSessions.put_pref(token, :not_a_pref, 1)
      assert %{prefs: prefs} = OperatorSessions.snapshot(token)
      assert level(prefs) == 40
    end

    test "clamps out-of-range values" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      assert {:ok, prefs} = OperatorSessions.put_pref(token, :pmc_level, 5000)
      assert level(prefs) == Operator.max_level()
    end
  end

  describe "progress" do
    test "is seeded once from the browser and not clobbered by a later push" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      # A real slice key: `Progress.normalize/1` allow-lists them (see
      # `Progress.slice_keys/0`), so a placeholder like "a" would be discarded
      # before it ever reached the session.
      assert {:ok, seeded} =
               OperatorSessions.seed_progress(token, blob(%{"completed_tasks" => ["debut"]}))

      assert Progress.get(seeded, :pvp, "completed_tasks") == ["debut"]

      # A second tab connecting must not roll back work done since.
      assert :unchanged =
               OperatorSessions.seed_progress(token, blob(%{"completed_tasks" => ["shortage"]}))

      assert %{progress: progress, progress_seeded?: true} = OperatorSessions.snapshot(token)
      assert Progress.get(progress, :pvp, "completed_tasks") == ["debut"]
    end

    test "merges patches so each page owns only its own keys" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      OperatorSessions.merge_progress(token, :pvp, %{"items_watchlist" => ["a"]})
      OperatorSessions.merge_progress(token, :pvp, %{"flea_favorites" => ["b"]})

      assert %{progress: progress} = OperatorSessions.snapshot(token)

      assert Progress.slice(progress, :pvp) == %{
               "items_watchlist" => ["a"],
               "flea_favorites" => ["b"]
             }
    end

    test "a write to one game mode never touches the other" do
      # The core of per-mode progress: PVP and PVE are separate playthroughs, and
      # a shallow merge over the whole blob (what the flat layout did) would
      # replace the entire `modes` map and wipe the mode not being written.
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      OperatorSessions.merge_progress(token, :pvp, %{"tasks_watchlist" => ["debut"]})
      OperatorSessions.merge_progress(token, :pve, %{"tasks_watchlist" => ["shootout-picnic"]})

      assert %{progress: progress} = OperatorSessions.snapshot(token)
      assert Progress.get(progress, :pvp, "tasks_watchlist") == ["debut"]
      assert Progress.get(progress, :pve, "tasks_watchlist") == ["shootout-picnic"]
    end

    test "a client push cannot revert a write that beat it" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      OperatorSessions.merge_progress(token, :pvp, %{"items_watchlist" => ["a"]})

      assert :unchanged = OperatorSessions.seed_progress(token, Progress.empty())
      assert %{progress: progress} = OperatorSessions.snapshot(token)
      assert Progress.get(progress, :pvp, "items_watchlist") == ["a"]
    end

    test "a write does not suppress the browser's cold-boot hydration" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.merge_progress(token, :pvp, %{"items_watchlist" => ["a"]})

      # The browser has still never spoken, so its blob is owed a hearing.
      assert %{progress_seeded?: false} = OperatorSessions.snapshot(token)
    end

    test "seeding keeps server keys but adopts keys only the browser knows" do
      # Guards a narrow race with real consequences: if a write lands before the
      # browser's `eft:restore`, a replace-or-drop rule would discard the
      # operator's whole stored progress (and then overwrite their localStorage).
      # The per-mode layout widens it: the adoption has to happen slice by slice,
      # or a write in one mode would swallow the browser's other mode entirely.
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      # A write beats the client's restore to it.
      OperatorSessions.merge_progress(token, :pvp, %{"items_watchlist" => ["new"]})

      assert {:ok, progress} =
               OperatorSessions.seed_progress(token, %{
                 "modes" => %{
                   "pvp" => %{"items_watchlist" => ["stale"], "completed_tasks" => ["debut"]},
                   "pve" => %{"items_watchlist" => ["pve-only"]}
                 }
               })

      # Server key wins; browser-only keys are adopted rather than lost...
      assert Progress.slice(progress, :pvp) == %{
               "items_watchlist" => ["new"],
               "completed_tasks" => ["debut"]
             }

      # ...including the whole untouched mode.
      assert Progress.get(progress, :pve, "items_watchlist") == ["pve-only"]
    end

    test "a malformed blob degrades to empty rather than raising" do
      # localStorage is user-writable and survives deploys, so every entry point
      # has to survive garbage.
      token = new_token()
      OperatorSessions.snapshot(token, create: true)

      assert :unchanged = OperatorSessions.seed_progress(token, %{"modes" => "not-a-map"})
      assert %{progress: progress} = OperatorSessions.snapshot(token)
      assert progress == Progress.empty()
    end
  end

  describe "reset/2" do
    test "returns prefs and progress to factory state" do
      # Without this the server would keep serving pre-reset values (it is
      # authoritative), and "Reset progress" would appear to do nothing.
      token = new_token()

      OperatorSessions.snapshot(token,
        seed_prefs: %{"modes" => %{"pvp" => %{"pmc_level" => 50}}},
        create: true
      )

      OperatorSessions.merge_progress(token, :pvp, %{"items_watchlist" => ["a"]})
      OperatorSessions.merge_progress(token, :pve, %{"items_watchlist" => ["b"]})

      assert {:ok, _snapshot} = OperatorSessions.reset(token)

      assert %{prefs: prefs, progress: progress, progress_seeded?: false} =
               OperatorSessions.snapshot(token)

      # Both modes, not just the active one.
      assert prefs == Operator.defaults()
      assert progress == Progress.empty()
    end

    test "is a no-op when the operator has no session" do
      # Nothing to forget, and it must not allocate one just to clear it.
      token = new_token()

      assert :unchanged = OperatorSessions.reset(token)
      refute OperatorSessions.alive?(token)
    end
  end

  describe "cross-tab broadcasts" do
    test "a pref change is published to the operator's other tabs" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.subscribe(token)

      # Mutate from another process so the broadcast isn't stamped with our pid.
      other = spawn_writer(token, fn -> OperatorSessions.put_pref(token, :faction, "bear") end)

      # The whole pref set is published, because a `:mode` change moves several
      # values at once and a subscriber has to re-derive rather than patch one.
      assert_receive {:operator_session, ^other, {:prefs_changed, prefs}}
      assert Operator.get_pref(prefs, :faction) == :bear
    end

    test "a progress change is published" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.subscribe(token)

      patch = %{"items_watchlist" => ["a"]}
      other = spawn_writer(token, fn -> OperatorSessions.merge_progress(token, :pvp, patch) end)

      assert_receive {:operator_session, ^other, {:progress_changed, progress}}
      assert Progress.get(progress, :pvp, "items_watchlist") == ["a"]
    end

    test "carries the originating pid so a tab can skip its own echo" do
      token = new_token()
      OperatorSessions.snapshot(token, create: true)
      OperatorSessions.subscribe(token)

      OperatorSessions.put_pref(token, :mode, "pve")

      me = self()
      assert_receive {:operator_session, ^me, {:prefs_changed, %{mode: :pve}}}
    end
  end

  describe "lifetime" do
    test "a session shuts itself down after its idle timeout" do
      # Sessions are deliberately NOT linked to a socket (a reload or a brief
      # network drop must not discard state), so the idle timeout is the only
      # thing bounding memory on a public, account-free site.
      token = new_token()

      pid =
        start_supervised!(
          {EftBuddy.OperatorSession, token: token, seed_prefs: %{}, idle_timeout: 10},
          restart: :temporary
        )

      ref = Process.monitor(pid)
      # The DOWN message is the assertion: `alive?/1` is Registry-backed and its
      # entry is reaped asynchronously, so it can briefly lag the exit.
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "activity postpones the idle shutdown" do
      token = new_token()

      pid =
        start_supervised!(
          {EftBuddy.OperatorSession, token: token, seed_prefs: %{}, idle_timeout: 150},
          restart: :temporary
        )

      ref = Process.monitor(pid)
      Process.sleep(100)
      # A call resets the timer, so the session must outlive the original window.
      assert %{prefs: _prefs} = GenServer.call(pid, :snapshot)
      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100
      assert Process.alive?(pid)
    end
  end

  test "an unknown pref key or dead session never raises" do
    # Callers are LiveView mounts; degrading quietly is required, because the
    # browser still holds the durable copy.
    dead = new_token()

    assert :unchanged = OperatorSessions.put_pref(nil, :mode, "pve") |> normalize_nil()
    assert :unchanged = OperatorSessions.merge_progress(nil, :pvp, %{})
    assert :unchanged = OperatorSessions.reset(nil)
    refute OperatorSessions.alive?(dead)
  end

  # `put_pref/4` with no token still validates (so an optimistic render is
  # possible) - collapse it for the "never raises" assertion above.
  defp normalize_nil({:ok, _value}), do: :unchanged
  defp normalize_nil(other), do: other

  # A progress blob carrying `slice` as the PVP mode's slice.
  defp blob(slice), do: %{"modes" => %{"pvp" => slice}}

  defp spawn_writer(_token, fun) do
    test = self()

    pid =
      spawn(fn ->
        fun.()
        send(test, :written)
      end)

    assert_receive :written
    pid
  end
end
