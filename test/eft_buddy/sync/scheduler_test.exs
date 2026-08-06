defmodule EftBuddy.Sync.SchedulerTest do
  @moduledoc """
  The shell nine syncers wear, tested against synthetic modules rather than the
  real feeds — every real one would hit the network or the database to prove
  something that is purely about timers and locks.

  What matters here is the stuff that used to be nine copies: which offset arms
  the first run, that contention is a short retry rather than a lost cycle, and
  that jitter cannot swamp a stagger.
  """
  use ExUnit.Case, async: false

  alias EftBuddy.Sync.Scheduler

  # `bootstrap: :ran` — Bootstrap runs this feed itself, so the first scheduled
  # run is a full interval out.
  defmodule RanFeed do
    use EftBuddy.Sync.Scheduler,
      label: "ProbeRanSync",
      interval: 1_000,
      stagger: 200,
      bootstrap: :ran,
      config_key: :probe_ran

    @impl EftBuddy.Sync.Scheduler
    def do_run, do: {:ok, %{probe: true}}
  end

  # `bootstrap: :released` — Bootstrap has NOT run this feed, so the first run is
  # only its stagger away.
  defmodule ReleasedFeed do
    use EftBuddy.Sync.Scheduler,
      label: "ProbeReleasedSync",
      interval: 1_000,
      stagger: 200,
      bootstrap: :released

    @impl EftBuddy.Sync.Scheduler
    def do_run, do: {:ok, %{probe: true}}
  end

  defmodule HookedFeed do
    use EftBuddy.Sync.Scheduler,
      label: "ProbeHookedSync",
      interval: 1_000,
      bootstrap: :chained

    @impl EftBuddy.Sync.Scheduler
    def do_run, do: {:error, :no_tasks}

    @impl EftBuddy.Sync.Scheduler
    def next_interval({:error, :no_tasks}, _interval), do: 42
    def next_interval(_result, interval), do: interval

    @impl EftBuddy.Sync.Scheduler
    def handle_extra_cast(:custom, state), do: {:noreply, Map.put(state, :got_custom, true)}
    def handle_extra_cast(_msg, state), do: {:noreply, state}
  end

  describe "the bootstrap offset" do
    test ":ran arms a full interval out, because the work already happened" do
      # Arming at zero would immediately re-sync a snapshot Bootstrap wrote
      # moments earlier. This distinction used to live only in a comment repeated
      # across five modules.
      assert RanFeed.bootstrap_mode() == :ran
      assert RanFeed.interval_ms() == 1_000
      assert RanFeed.stagger_ms() == 200
    end

    test ":released arms at its stagger, because the feed has never run" do
      assert ReleasedFeed.bootstrap_mode() == :released
    end

    test "a bootstrap cast cancels the standing fallback timer and re-arms" do
      {:ok, pid} = GenServer.start_link(RanFeed, [], [])
      %{timer: first} = :sys.get_state(pid)

      GenServer.cast(pid, :bootstrap_complete)
      %{timer: second} = :sys.get_state(pid)

      assert first != second, "the fallback timer must be replaced, not left racing the new one"
      assert Process.cancel_timer(second) != false

      GenServer.stop(pid)
    end
  end

  describe "the lock" do
    test "a second holder gets :already_running rather than running concurrently" do
      # This failed when the macro first inherited the syncers' lock shape, and
      # the failure was real rather than a test bug. `:global.set_lock/3` takes
      # `{ResourceId, LockRequesterId}`, and every syncer passed
      # `{__MODULE__, :running}` — so the requester was the constant `:running`
      # and `:global`, which grants re-entrantly to the same requester, handed the
      # lock to everyone who asked. The "cluster-wide singleton" excluded nothing,
      # on one node or across the cluster.
      parent = self()

      task =
        Task.async(fn ->
          RanFeed.with_lock(fn ->
            send(parent, :holding)
            assert_receive :release, 2_000
            :held
          end)
        end)

      assert_receive :holding, 2_000
      assert RanFeed.run() == {:error, :already_running}

      send(task.pid, :release)
      assert Task.await(task) == :held
    end

    test "the lock is released even when the run raises" do
      defmodule ExplodingFeed do
        use EftBuddy.Sync.Scheduler, label: "ProbeBoomSync", interval: 1_000

        @impl EftBuddy.Sync.Scheduler
        def do_run, do: raise("boom")
      end

      assert_raise RuntimeError, fn -> ExplodingFeed.run() end

      # If the `after` had not fired, this would answer :already_running.
      assert_raise RuntimeError, fn -> ExplodingFeed.run() end
    end

    test "lock_id defaults to the module and can be shared explicitly" do
      defmodule SharedLockFeed do
        use EftBuddy.Sync.Scheduler,
          label: "ProbeSharedSync",
          interval: 1_000,
          lock: {EftBuddy.Sync.SchedulerTest.RanFeed, :running}

        @impl EftBuddy.Sync.Scheduler
        def do_run, do: {:ok, :shared}
      end

      assert RanFeed.lock_id() == {RanFeed, :running}
      assert SharedLockFeed.lock_id() == RanFeed.lock_id()
    end
  end

  describe "next_interval" do
    test "contention retries in minutes rather than losing a whole cycle" do
      # What makes a lock shared across a family of feeds affordable: a loser
      # comes back soon instead of waiting out its interval.
      assert RanFeed.next_interval({:error, :already_running}, 12 * 60 * 60 * 1_000) ==
               Scheduler.contention_retry_ms()

      assert Scheduler.contention_retry_ms() < 10 * 60 * 1_000
    end

    test "an ordinary result uses the configured interval" do
      assert RanFeed.next_interval({:ok, %{}}, 999) == 999
    end

    test "an override is honoured and still handles the default cases" do
      assert HookedFeed.next_interval({:error, :no_tasks}, 999) == 42
      assert HookedFeed.next_interval({:ok, %{}}, 999) == 999
    end
  end

  describe "hooks" do
    test "after_run defaults to a no-op and can be overridden" do
      assert RanFeed.after_run({:ok, %{}}) == :ok
    end

    test "an extra cast reaches handle_extra_cast without splitting handle_cast" do
      {:ok, pid} = GenServer.start_link(HookedFeed, [], [])

      GenServer.cast(pid, :custom)
      assert %{got_custom: true} = :sys.get_state(pid)

      # An unknown cast must not crash the server, or a stray message would take
      # the feed's timer down with it.
      GenServer.cast(pid, :nonsense)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "jitter" do
    test "is capped, so it cannot swamp the stagger table" do
      # ±10% of a twelve-hour interval is 0-72 minutes of one-sided drift against
      # staggers spaced 25 minutes apart — the schedule would have been fiction.
      twelve_hours = 12 * 60 * 60 * 1_000

      for _ <- 1..500 do
        assert Scheduler.jitter(twelve_hours) <= Scheduler.max_jitter_ms() + 1
      end

      assert Scheduler.max_jitter_ms() <= 5 * 60 * 1_000
    end

    test "stays proportional below the cap" do
      for _ <- 1..500 do
        assert Scheduler.jitter(10_000) <= 1_001
      end
    end

    test "a zero or negative delay jitters by nothing rather than raising" do
      assert Scheduler.jitter(0) == 0
      assert Scheduler.jitter(-5) == 0
      assert Scheduler.jitter(nil) == 0
    end
  end

  describe "interval overrides" do
    test "interval_ms is the compile-time default, effective_interval_ms is not" do
      # They are deliberately different functions. `freshness_test.exs` asserts
      # `budget >= 2 * interval_ms()`, so if that returned a runtime override an
      # operator could break the health probe's invariant in production while the
      # test — reading default config — stayed green.
      original = Application.get_env(:eft_buddy, :sync_intervals)
      on_exit(fn -> Application.put_env(:eft_buddy, :sync_intervals, original || []) end)

      Application.put_env(:eft_buddy, :sync_intervals, probe_ran: 7_777)

      assert RanFeed.effective_interval_ms() == 7_777
      assert RanFeed.interval_ms() == 1_000, "the budget's reference value must not move"
    end

    test "an unusable override falls back to the default rather than failing to start" do
      original = Application.get_env(:eft_buddy, :sync_intervals)
      on_exit(fn -> Application.put_env(:eft_buddy, :sync_intervals, original || []) end)

      Application.put_env(:eft_buddy, :sync_intervals, probe_ran: "nonsense")

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert RanFeed.effective_interval_ms() == 1_000
             end) =~ "not a usable interval"
    end

    test "a feed with no config_key ignores the override map entirely" do
      original = Application.get_env(:eft_buddy, :sync_intervals)
      on_exit(fn -> Application.put_env(:eft_buddy, :sync_intervals, original || []) end)

      Application.put_env(:eft_buddy, :sync_intervals, probe_released: 5)

      assert ReleasedFeed.effective_interval_ms() == 1_000
    end
  end

  describe "safe_run" do
    test "a crashing run returns an error rather than taking the process down" do
      defmodule CrashFeed do
        use EftBuddy.Sync.Scheduler, label: "ProbeCrashSync", interval: 1_000

        @impl EftBuddy.Sync.Scheduler
        def do_run, do: raise("kaboom")
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:crash, "kaboom"}} = CrashFeed.safe_run()
        end)

      assert log =~ "kaboom"
    end

    test "a skip is reported as a skip, not flattened into an error" do
      defmodule SkipFeed do
        use EftBuddy.Sync.Scheduler, label: "ProbeSkipSync", interval: 1_000

        @impl EftBuddy.Sync.Scheduler
        def do_run, do: {:skip, :nothing_to_do}
      end

      ExUnit.CaptureLog.capture_log(fn ->
        assert SkipFeed.safe_run() == {:skip, :nothing_to_do}
      end)
    end
  end
end
