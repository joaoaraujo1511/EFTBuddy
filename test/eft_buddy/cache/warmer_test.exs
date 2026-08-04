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

  @doc false
  def probe_warm(key), do: Cache.fetch(key, ["ProbeSync"], fn -> :warmed end)

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

  describe "the registry" do
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
