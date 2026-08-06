defmodule EftBuddy.Sync.RegistryTest do
  @moduledoc """
  The registry exists because three lists that had to agree did not.

  `EftBuddy.Application` held the supervision children, `Bootstrap.do_run/0` held
  the cold-start order, and `notify_schedulers/0` held who receives the
  completion cast. `EftBuddy.Items.Sync` was missing from the third. Nothing
  failed and nothing logged — it simply never got the cast, so instead of
  anchoring its first run to the end of the cold start it armed a timer in
  `init/1` and drifted from boot forever.

  That is the failure this file is here to make impossible, and the first test is
  the one that matters: a feed that exists on disk but is not registered fails
  the suite rather than running on the wrong schedule in silence.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Sync.Freshness
  alias EftBuddy.Sync.Registry

  # Every module under `lib/eft_buddy/**/sync.ex`, by its declared module name.
  # Read off disk rather than listed here, so adding a feed cannot also quietly
  # add it to the expectations.
  defp sync_modules_on_disk do
    "lib/eft_buddy/**/sync.ex"
    |> Path.wildcard()
    |> Enum.map(fn path ->
      [_, name] = Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)\s+do/, File.read!(path))
      Module.concat([name])
    end)
  end

  test "every sync module on disk is registered" do
    # THE ASSERTION THIS FILE EXISTS FOR. An unregistered feed is not started by
    # the supervisor and never receives `:bootstrap_complete`, and neither
    # produces an error — it just runs on the wrong schedule, or not at all.
    registered = MapSet.new(Registry.children())
    on_disk = MapSet.new(sync_modules_on_disk())

    missing = MapSet.difference(on_disk, registered)

    assert MapSet.size(missing) == 0,
           "these sync modules exist but are not in EftBuddy.Sync.Registry: " <>
             inspect(MapSet.to_list(missing))
  end

  test "every registered feed exists on disk" do
    # The other direction: a registry entry for a module that was renamed or
    # deleted would crash the supervisor at boot, which is louder but no more
    # welcome.
    on_disk = MapSet.new(sync_modules_on_disk())

    for mod <- Registry.children() do
      assert MapSet.member?(on_disk, mod), "#{inspect(mod)} is registered but has no sync.ex"
    end
  end

  test "the registry is free of duplicates" do
    mods = Registry.children()
    assert length(mods) == length(Enum.uniq(mods))
  end

  describe "each feed's declared shape matches the module's" do
    test "every feed uses the scheduler and exposes its schedule" do
      for mod <- Registry.children() do
        # `function_exported?/3` answers false for a module that has not been
        # loaded yet, so without this the test passes or fails depending on what
        # else the suite happened to touch first.
        Code.ensure_loaded!(mod)

        assert function_exported?(mod, :interval_ms, 0), "#{inspect(mod)} has no interval_ms/0"
        assert function_exported?(mod, :stagger_ms, 0), "#{inspect(mod)} has no stagger_ms/0"
        assert function_exported?(mod, :run, 0), "#{inspect(mod)} has no run/0"
        assert is_integer(mod.interval_ms()) and mod.interval_ms() > 0
      end
    end

    test "the registry's bootstrap mode agrees with the module's own" do
      # Two declarations of the same fact, which is exactly the shape that drifts.
      # The registry needs it to decide who gets the cast; the module needs it to
      # compute its own offset. Pinned rather than deduplicated, because the
      # registry is read at supervision time and the module attribute at compile
      # time.
      for feed <- Registry.all() do
        assert feed.bootstrap == feed.mod.bootstrap_mode(),
               "#{inspect(feed.mod)}: registry says #{feed.bootstrap}, " <>
                 "module says #{feed.mod.bootstrap_mode()}"
      end
    end

    test "every feed's label has a staleness budget" do
      # A feed with no budget is invisible to `/health/sync`: it can stop
      # completely and the probe stays green.
      for mod <- Registry.children() do
        assert Freshness.budget_seconds(mod.label()) != nil,
               "#{inspect(mod)} emits #{mod.label()}, which no Freshness budget covers"
      end
    end
  end

  describe "the completion cast" do
    test "goes to :ran and :released feeds, and to nothing else" do
      notifiable = MapSet.new(Registry.notifiable())

      for feed <- Registry.all() do
        if feed.bootstrap in [:ran, :released] do
          assert MapSet.member?(notifiable, feed.mod)
        else
          refute MapSet.member?(notifiable, feed.mod),
                 "#{inspect(feed.mod)} is #{feed.bootstrap}; it is armed by something else"
        end
      end
    end

    test "includes Items.Sync, which the hardcoded list used to omit" do
      # The specific regression. It cost nothing visible and everything
      # schedule-wise.
      assert EftBuddy.Items.Sync in Registry.notifiable()
    end

    test "every notifiable feed can actually receive the cast" do
      # A `GenServer.cast/2` with no matching clause is a FunctionClauseError
      # inside the server, which crashes it and takes its timers with it. Adding
      # a feed to `notifiable/0` without giving it the clause is therefore not a
      # missed schedule but a restart loop.
      for mod <- Registry.notifiable() do
        Code.ensure_loaded!(mod)

        assert function_exported?(mod, :handle_cast, 2),
               "#{inspect(mod)} is sent :bootstrap_complete but handles no casts"
      end
    end
  end

  describe "the stagger table" do
    test "no two feeds on the same upstream collide, at any cycle coincidence" do
      # THE INVARIANT THAT MAKES THE SCHEDULE MEAN ANYTHING.
      #
      # Three cycles run at once — 6h, 12h and 24h — so they periodically
      # coincide, and two feeds whose staggers are congruent modulo the shortest
      # cycle collide on every coincidence, forever. Comparing the raw staggers
      # would miss that entirely: 0h50 and 6h50 look 6 hours apart and are the
      # same instant every other cycle.
      #
      # Reduced mod 6h and kept ≥20 minutes apart, they never collide, whatever
      # the cycle lengths. Feeds on different upstreams contend on nothing, so
      # the rule is per-group.
      modulus = Registry.shortest_cycle_ms()
      min_gap = Registry.min_stagger_gap_ms()

      Registry.all()
      |> Enum.group_by(& &1.upstream)
      |> Enum.each(fn {upstream, feeds} ->
        slots =
          feeds
          |> Enum.map(&{&1.mod, rem(&1.mod.stagger_ms(), modulus)})
          |> Enum.sort_by(&elem(&1, 1))

        slots
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [{mod_a, a}, {mod_b, b}] ->
          assert b - a >= min_gap,
                 "#{upstream}: #{inspect(mod_a)} (#{div(a, 60_000)}m) and " <>
                   "#{inspect(mod_b)} (#{div(b, 60_000)}m) are #{div(b - a, 60_000)}m apart " <>
                   "mod 6h; they will overlap on every cycle coincidence"
        end)
      end)
    end

    test "jitter cannot swamp the minimum gap" do
      # Uncapped ±10% jitter at a twelve-hour interval is 0-72 minutes of
      # one-sided drift, which makes a 20-minute stagger table decorative. The
      # cap has to stay comfortably under it.
      assert EftBuddy.Sync.Scheduler.max_jitter_ms() < Registry.min_stagger_gap_ms()
    end

    test "every stagger is shorter than the cycle it sits in" do
      # A stagger longer than its own interval would push a feed past its next
      # tick, so its first scheduled run would land after the second.
      for feed <- Registry.all() do
        assert feed.mod.stagger_ms() < feed.mod.interval_ms(),
               "#{inspect(feed.mod)}: stagger #{feed.mod.stagger_ms()}ms exceeds its " <>
                 "own #{feed.mod.interval_ms()}ms interval"
      end
    end
  end

  describe "the cold-start sequence" do
    test "runs items first, since everything below resolves against them" do
      assert [%{key: :items} | _] = Registry.cold_start_steps()
    end

    test "maps precede tasks, so tasks.map_id resolves against the rich map set" do
      labels = Enum.map(Registry.cold_start_steps(), & &1.label)

      assert index_of(labels, "Maps") < index_of(labels, "Tasks")
    end

    test "barters and crafts come after items, hideout and tasks" do
      labels = Enum.map(Registry.cold_start_steps(), & &1.label)
      barters = index_of(labels, "Items (barters & crafts)")

      assert index_of(labels, "Items (items + prices)") < barters
      assert index_of(labels, "Hideout") < barters
      assert index_of(labels, "Tasks") < barters
    end

    test "every step is callable and every dependency is declared before its dependent" do
      steps = Registry.cold_start_steps()

      Enum.reduce(steps, MapSet.new(), fn step, seen ->
        assert is_function(step.run, 0), "#{step.label}: :run must be a zero-arity function"

        case Map.get(step, :requires) do
          nil ->
            :ok

          key ->
            assert MapSet.member?(seen, key),
                   "#{step.label} requires #{key}, which no earlier step provides"
        end

        case Map.get(step, :key) do
          nil -> seen
          key -> MapSet.put(seen, key)
        end
      end)
    end
  end

  defp index_of(list, value) do
    idx = Enum.find_index(list, &(&1 == value))
    assert idx, "expected #{inspect(value)} in #{inspect(list)}"
    idx
  end
end
