defmodule EftBuddy.Cache.WarmerTest do
  @moduledoc """
  The warmer's job is to make cold reads the server's problem instead of a
  visitor's. Its *risk* is entirely different: it runs off the same telemetry
  event as cache invalidation, and `:telemetry` permanently detaches a handler
  that raises. So the tests that matter most here are not "does it warm" but
  "can it take invalidation down with it" — the answer to which must stay no
  even when every warm spec is broken.
  """
  # `async: false`: these flip the global `:cache_enabled` flag, swap the global
  # warm registry, and assert on a named GenServer.
  use ExUnit.Case, async: false

  alias EftBuddy.Cache
  alias EftBuddy.Cache.Warmer

  @sync_event [:eft_buddy, :sync, :stop]

  setup do
    original_enabled = Application.get_env(:eft_buddy, :cache_enabled)
    original_specs = Application.get_env(:eft_buddy, :cache_warm_specs)

    Application.put_env(:eft_buddy, :cache_enabled, true)

    # Drain first, THEN clear. Warming is asynchronous, so a batch triggered by
    # the previous test can otherwise land after this clear and write an entry
    # into a table this test believes is empty — a seed-dependent failure that
    # looks like a bug in the code under test.
    wait_until_idle()
    Cache.clear()

    on_exit(fn ->
      wait_until_idle()
      Cache.clear()
      Application.put_env(:eft_buddy, :cache_enabled, original_enabled)

      # Back to the test env's empty registry (config/test.exs), so a flush that
      # fires after this test cannot reach a spec that touches the database.
      Application.put_env(:eft_buddy, :cache_warm_specs, original_specs || [])
    end)

    :ok
  end

  # The warmer collects sources over a debounce window before flushing, so every
  # assertion here has to outwait it. Polling beats a fixed sleep: it passes as
  # soon as the work lands instead of always costing the worst case.
  defp eventually(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    fun.()
  rescue
    e ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_eventually(fun, deadline)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp wait_until_idle(attempts \\ 200) do
    cond do
      attempts <= 0 -> :ok
      Warmer.busy?() -> Process.sleep(10) && wait_until_idle(attempts - 1)
      true -> :ok
    end
  end

  # For the NEGATIVE assertions ("nothing was warmed"), which cannot poll —
  # there is no arrival to wait for, so the only option is to outwait the
  # debounce window and then look. Derived from the warmer's own configured
  # window so this does not silently stop covering anything if that changes.
  defp settle, do: Process.sleep(Warmer.debounce_ms() * 4 + 200)

  defp emit_sync_stop(label) do
    :telemetry.execute(
      @sync_event,
      %{duration_ms: 1, warnings: 0, errors: 0, refusals: 0},
      %{label: label, outcome: :ok}
    )
  end

  # A spec that writes a cache entry without touching the database — the suite
  # runs inside an Ecto sandbox that a spawned warm process does not own.
  defp probe_spec(label, sources, key) do
    %{
      label: label,
      sources: sources,
      mfa: {__MODULE__, :probe_warm, [key]}
    }
  end

  defp with_keys(spec, keys), do: Map.put(spec, :keys, keys)

  # Installs a spec that counts how many times its MFA actually ran, which is
  # the only way to tell "the probe skipped it" from "it rebuilt an identical
  # value". `:ttl_ms` lets a test reach the state the shipped bug left
  # production in — warmed, then expired, with the next sync hours away —
  # without waiting out a real TTL. Returns the counter and the key.
  defp counting_spec_installed(label, key, opts \\ []) do
    counter = :counters.new(1, [])

    Application.put_env(:eft_buddy, :cache_warm_specs, [
      %{
        label: label,
        sources: ["HideoutSync"],
        keys: [key],
        periodic: Keyword.get(opts, :periodic, true),
        mfa: {__MODULE__, :probe_warm_counted, [key, counter, Keyword.get(opts, :ttl_ms)]}
      }
    ])

    {counter, key}
  end

  @doc false
  def probe_warm(key), do: Cache.fetch(key, ["ProbeSync"], fn -> :warmed end)

  @doc false
  def probe_warm_counted(key, counter, ttl_ms) do
    fun = fn ->
      :counters.add(counter, 1, 1)
      :warmed
    end

    opts = if ttl_ms, do: [ttl_ms: ttl_ms], else: []

    Cache.fetch(key, ["ProbeSync"], fun, opts)
  end

  @doc false
  def probe_raise(_key), do: raise("deliberate warm failure")

  describe "warming on sync completion" do
    test "a finished sync rebuilds the entries that syncer owns" do
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.hideout", ["HideoutSync"], {:warm_test, :hideout})
      ])

      assert Cache.size() == 0

      emit_sync_stop("HideoutSync")

      eventually(fn ->
        assert Cache.entries() |> Enum.map(& &1.key) == [{:warm_test, :hideout}]
      end)
    end

    test "a labelled per-mode run warms its base syncer's specs" do
      # Runs label themselves "PricesSync:regular" / "PricesSync:pve". Both write
      # the same tables, so either must trigger the warm registered on the base.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.prices", ["PricesSync"], {:warm_test, :prices})
      ])

      emit_sync_stop("PricesSync:pve")

      eventually(fn -> assert Cache.size() == 1 end)
    end

    test "an unrelated syncer finishing warms nothing" do
      # The whole efficiency argument rests on this. Without per-source
      # filtering, Bootstrap's seven consecutive feeds would each rebuild every
      # dataset in the registry.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.hideout", ["HideoutSync"], {:warm_test, :hideout})
      ])

      emit_sync_stop("MapsSync")

      # Outwait the debounce window and confirm nothing arrived.
      settle()
      assert Cache.size() == 0
    end

    test "does nothing at all while the cache is disabled" do
      # Dev and test run this way. A warm here would be pure cost: real queries
      # whose results are immediately discarded.
      Application.put_env(:eft_buddy, :cache_enabled, false)

      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.hideout", ["HideoutSync"], {:warm_test, :hideout})
      ])

      emit_sync_stop("HideoutSync")

      settle()
      assert Cache.size() == 0
    end
  end

  describe "the warmer cannot damage invalidation" do
    test "a raising warm spec leaves BOTH telemetry handlers attached" do
      # The failure this module is shaped around. `:telemetry` detaches a
      # handler that raises, permanently and with only a log line. If warming
      # shared the cache's handler, one bad spec would silently demote the whole
      # cache to its 20-minute TTL — arriving at the exact failure the TTL exists
      # to bound, through the mechanism meant to prevent it.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        %{
          label: "probe.explodes",
          sources: ["HideoutSync"],
          mfa: {__MODULE__, :probe_raise, [:k]}
        }
      ])

      emit_sync_stop("HideoutSync")
      settle()

      attached = :telemetry.list_handlers(@sync_event) |> Enum.map(& &1.id)

      assert {EftBuddy.Cache, :invalidate} in attached,
             "invalidation handler was detached by a failing warm"

      assert {Warmer, :warm} in attached, "warm handler detached itself"
    end

    test "a raising warm spec leaves the warmer alive and still serving" do
      pid = Process.whereis(Warmer)

      Application.put_env(:eft_buddy, :cache_warm_specs, [
        %{
          label: "probe.explodes",
          sources: ["HideoutSync"],
          mfa: {__MODULE__, :probe_raise, [:k]}
        }
      ])

      emit_sync_stop("HideoutSync")
      settle()

      assert Process.whereis(Warmer) == pid, "warmer restarted"

      # And it still works afterwards, which is the part that proves the failure
      # was contained rather than merely survived.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.ok", ["HideoutSync"], {:warm_test, :recovered})
      ])

      emit_sync_stop("HideoutSync")

      eventually(fn -> assert Cache.size() == 1 end)
    end

    test "invalidation still fires for a source whose warm fails" do
      Cache.fetch({:warm_test, :existing}, ["HideoutSync"], fn -> :original end)
      assert Cache.size() == 1

      Application.put_env(:eft_buddy, :cache_warm_specs, [
        %{
          label: "probe.explodes",
          sources: ["HideoutSync"],
          mfa: {__MODULE__, :probe_raise, [:k]}
        }
      ])

      emit_sync_stop("HideoutSync")

      # Dropped immediately by the invalidation handler, and the failing warm
      # that follows does not resurrect or block it.
      eventually(fn -> assert Cache.size() == 0 end, 2_000)
    end
  end

  describe "the repair tick" do
    test "an entry that expired between syncs is rebuilt without waiting for one" do
      # THE regression test for the failure that shipped: warming fired only on
      # sync completion, feeds run every 6-24 hours, and the TTL was 20 minutes.
      # Every warmed entry therefore expired and stayed cold until the next
      # sync, and the first visitor after that paid the full cold read. On the
      # VM this left 5 of 19 specs live and the hit rate at 25.6%.
      #
      # Nothing in this module covered the interaction between the two, which is
      # exactly why it was invisible.
      {counter, key} =
        counting_spec_installed("probe.expires", {:warm_test, :expires}, ttl_ms: 50)

      emit_sync_stop("HideoutSync")
      eventually(fn -> assert :counters.get(counter, 1) == 1 end)

      # Outlive the entry's own TTL. Asserting on the rebuild COUNT rather than
      # on `live?` at this point, because a short-TTL entry's live window is
      # narrower than any poll interval — the count is what actually
      # distinguishes "the tick rebuilt it" from "it never expired".
      Process.sleep(80)
      refute Cache.live?(key)

      # Fire the tick directly rather than sleeping out the real five-minute
      # interval — the interval's *value* is asserted separately below.
      send(Process.whereis(Warmer), :repair)

      # The rebuild count is the whole property, and deliberately the only
      # assertion here. Checking `live?` afterwards would race the same short
      # TTL all over again — and "was it rebuilt without a sync" is what the
      # shipped bug got wrong, not "does a fresh entry read as live".
      eventually(fn -> assert :counters.get(counter, 1) == 2 end)
    end

    test "a spec whose entry is still live is skipped, not re-run" do
      # What makes ticking affordable. The probe reads one integer per key; the
      # alternative is calling the read and letting `fetch/4` hit, which copies
      # every cached value into the warmer on every pass.
      {counter, _} = counting_spec_installed("probe.counted", {:warm_test, :counted})

      emit_sync_stop("HideoutSync")
      eventually(fn -> assert Cache.live?({:warm_test, :counted}) end)
      eventually(fn -> assert :counters.get(counter, 1) == 1 end)

      send(Process.whereis(Warmer), :repair)
      settle()

      assert :counters.get(counter, 1) == 1, "a live spec was rebuilt by the repair tick"
    end

    test "a spec whose entry was deleted is rebuilt by the tick" do
      {counter, key} = counting_spec_installed("probe.counted", {:warm_test, :counted})

      emit_sync_stop("HideoutSync")
      eventually(fn -> assert :counters.get(counter, 1) == 1 end)

      Cache.clear()
      send(Process.whereis(Warmer), :repair)

      eventually(fn -> assert Cache.live?(key) end)
      assert :counters.get(counter, 1) == 2
    end

    test "the interval is derived from the cache TTL so the two cannot drift" do
      assert Warmer.repair_interval_ms() == div(Cache.default_ttl_ms(), 4)
    end

    test "a periodic: false spec is never run by the tick, only by its source" do
      {counter, key} =
        counting_spec_installed("probe.external", {:warm_test, :external}, periodic: false)

      send(Process.whereis(Warmer), :repair)
      settle()

      assert :counters.get(counter, 1) == 0, "a periodic: false spec was ticked"

      emit_sync_stop("HideoutSync")
      eventually(fn -> assert Cache.live?(key) end)
    end
  end

  describe "warm TTLs" do
    test "an entry lives as long as its owning feed's staleness budget" do
      # A 24-hour feed with a 20-minute entry is not a staleness bound, it is a
      # guarantee that the entry is cold for 23h40m of every cycle.
      assert Warmer.warm_ttl_ms(["HideoutSync"]) ==
               :timer.seconds(EftBuddy.Sync.Freshness.budget_seconds("HideoutSync"))
    end

    test "the strictest owner wins when several feeds contribute" do
      # `ammo.rounds` is fed by five syncers, one of which is the two-hourly
      # price budget. The entry should expire on that schedule: prices are the
      # first of its five ingredients that can go wrong.
      sources = ["AmmoSync", "ItemsSync", "PricesSync", "BartersSync", "CraftsSync"]

      assert Warmer.warm_ttl_ms(sources) ==
               :timer.seconds(EftBuddy.Sync.Freshness.budget_seconds("PricesSync"))
    end

    test "an unknown source falls back to the cache default rather than to zero" do
      assert Warmer.warm_ttl_ms(["NoSuchSync"]) == Cache.default_ttl_ms()
      assert Warmer.warm_ttl_ms([]) == Cache.default_ttl_ms()
    end
  end

  describe "suspension" do
    test "sources accumulate while suspended and flush once on resume" do
      # Bootstrap's steps are minutes apart, so the debounce collapses nothing:
      # without this the item catalogue is rebuilt four times during a cold
      # start, three of them against data the next step is about to overwrite.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.a", ["HideoutSync"], {:warm_test, :a}),
        probe_spec("probe.b", ["MapsSync"], {:warm_test, :b})
      ])

      Warmer.suspend()

      emit_sync_stop("HideoutSync")
      emit_sync_stop("MapsSync")
      settle()

      assert Cache.size() == 0, "a suspended warmer flushed anyway"

      Warmer.resume()

      eventually(fn ->
        assert Cache.entries() |> Enum.map(& &1.key) |> Enum.sort() ==
                 [{:warm_test, :a}, {:warm_test, :b}]
      end)
    end

    test "the warmer self-resumes if whoever suspended it never comes back" do
      # A warmer a crashing caller can switch off permanently is the same silent
      # failure as a detached telemetry handler. Bootstrap resumes from an
      # `after` block; this covers it being killed outright.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.a", ["HideoutSync"], {:warm_test, :a})
      ])

      Warmer.suspend()
      emit_sync_stop("HideoutSync")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Process.whereis(Warmer), :suspend_expired)
          eventually(fn -> assert Cache.size() == 1 end)
        end)

      assert log =~ "still suspended"
    end
  end

  describe "coverage" do
    test "reports which specs are live and which are cold" do
      # The signal that would have made the shipped failure obvious. Entry
      # count, memory and hit rate all looked plausible while two thirds of the
      # registry was expired; none of them can say "what should be warm is not".
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.a", ["HideoutSync"], {:warm_test, :a}) |> with_keys([{:warm_test, :a}]),
        probe_spec("probe.b", ["MapsSync"], {:warm_test, :b}) |> with_keys([{:warm_test, :b}])
      ])

      emit_sync_stop("HideoutSync")
      eventually(fn -> assert Cache.live?({:warm_test, :a}) end)

      summary = Warmer.coverage_summary()

      assert summary.total == 2
      assert summary.live == 1
      assert summary.cold == ["probe.b"]
    end

    test "the summary works with the warmer process not running" do
      # `EftBuddyWeb.Telemetry` is the FIRST child in the supervision tree and
      # this warmer is the fourth, so the poller's first measurement runs before
      # the GenServer exists. Routing the summary through a `call` made that
      # crash on every boot — observed in production as "Error when calling MFA
      # defined by measurement".
      #
      # Liveness comes from the registry and ETS, neither of which needs the
      # server, so the summary must not require it.
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        probe_spec("probe.a", ["HideoutSync"], {:warm_test, :a}) |> with_keys([{:warm_test, :a}])
      ])

      pid = Process.whereis(Warmer)
      :ok = Supervisor.terminate_child(EftBuddy.Supervisor, Warmer)
      refute Process.whereis(Warmer)

      try do
        assert %{total: 1, live: 0, cold: ["probe.a"]} = Warmer.coverage_summary()
        assert Warmer.emit_telemetry() == :ok
      after
        {:ok, _} = Supervisor.restart_child(EftBuddy.Supervisor, Warmer)
        assert Process.whereis(Warmer) != pid
      end
    end

    test "external specs are unprobed rather than reported cold forever" do
      Application.put_env(:eft_buddy, :cache_warm_specs, [
        %{
          label: "probe.external",
          sources: ["HideoutSync"],
          mfa: {__MODULE__, :probe_warm, [{:warm_test, :x}]},
          kind: :external,
          cost: :heavy,
          periodic: false,
          keys: []
        }
      ])

      assert [%{state: :unprobed}] = Warmer.coverage()
      assert Warmer.coverage_summary().cold == []
    end
  end

  describe "the registry" do
    test "the two dataset specs must never be ticked" do
      # Pinned BY NAME because the default is `periodic: true` and the next
      # person adding a dataset layer will copy an existing spec. Both are
      # unconditional multi-second rebuilds that raise `Dataset.ready?/1`'s
      # `:building` flag, so ticking them every five minutes would spend 14-26
      # seconds of every 300 pushing Items and Flea back onto the SQL path.
      by_label = Map.new(Warmer.default_specs(), &{&1.label, &1})

      for label <- ["dataset.catalog", "dataset.prices"] do
        spec = Map.fetch!(by_label, label)

        assert spec.kind == :external, "#{label} must stay :external"
        refute spec.periodic, "#{label} must never be run by the repair tick"
      end
    end

    test "every entry spec declares the keys it populates" do
      # `:keys` is what the repair tick probes. A spec without them is never
      # skipped (so it rebuilds on every tick) and never reported cold.
      for spec <- Warmer.default_specs(), spec.kind == :entry do
        assert spec.keys != [], "#{spec.label} declares no cache keys"
      end
    end

    test "single-entry specs are never heavy, and external specs always are" do
      # `:heavy` means "run alone, nothing else concurrent" — the right
      # treatment for a multi-second rebuild, and pure latency for a single
      # cached read. `:bulk` is deliberately NOT pinned either way: the two
      # hideout sets are a couple of queries covering ~100 entries and should
      # not queue behind a serial lane, while the item-detail build must.
      for spec <- Warmer.default_specs() do
        case spec.kind do
          :entry -> assert spec.cost == :light, "#{spec.label} is a single entry but heavy"
          :external -> assert spec.cost == :heavy, "#{spec.label} is external but light"
          :bulk -> assert spec.cost in [:light, :heavy]
        end
      end
    end

    test "every default spec names at least one syncer that actually exists" do
      # A spec whose source never fires is warmed once at boot and then never
      # again, which reads as "the cache works" right up until the data changes.
      # The labels are the ones `Sync.Reporter` emits, base form only.
      known =
        ~w(ItemsSync PricesSync FleaSettingsSync QuestItemsSync BartersSync CraftsSync
           HideoutSync TasksSync MapsSync WikiSync ChaptersSync EventsSync AmmoSync ArmorSync)

      for spec <- Warmer.default_specs(), source <- spec.sources do
        assert source in known,
               "#{spec.label} is invalidated by #{source}, which no sync run emits"
      end
    end

    test "every default spec points at a function that exists" do
      for %{label: label, mfa: {mod, fun, args}} <- Warmer.default_specs() do
        assert function_exported?(mod, fun, length(args)) or
                 (Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args))),
               "#{label} warms #{inspect(mod)}.#{fun}/#{length(args)}, which does not exist"
      end
    end
  end
end
