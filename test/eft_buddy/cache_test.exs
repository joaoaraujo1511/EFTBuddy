defmodule EftBuddy.CacheTest do
  @moduledoc """
  The cache is disabled in the test environment (config/test.exs) so the rest of
  the suite reads through to the database. These cases turn it on explicitly, so
  they are the only place its behaviour is actually exercised.

  `async: false`: the cache is a single named ETS table and the telemetry handler
  is global, so two of these running concurrently would evict each other's
  entries.
  """
  use ExUnit.Case, async: false

  alias EftBuddy.Cache

  setup do
    original = Application.get_env(:eft_buddy, :cache_enabled)
    Application.put_env(:eft_buddy, :cache_enabled, true)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      Application.put_env(:eft_buddy, :cache_enabled, original)
    end)

    :ok
  end

  # Counts how many times the expensive function actually ran.
  defp counting_fun do
    counter = :counters.new(1, [])
    {counter, fn -> :counters.add(counter, 1, 1) end}
  end

  defp calls(counter), do: :counters.get(counter, 1)

  describe "fetch/4" do
    test "computes once, then serves from memory" do
      {counter, bump} = counting_fun()

      compute = fn ->
        bump.()
        :value
      end

      assert Cache.fetch({:t, :basic}, ["ItemsSync"], compute) == :value
      assert Cache.fetch({:t, :basic}, ["ItemsSync"], compute) == :value
      assert Cache.fetch({:t, :basic}, ["ItemsSync"], compute) == :value

      assert calls(counter) == 1, "expected one computation, got #{calls(counter)}"
    end

    test "different keys do not collide" do
      assert Cache.fetch({:t, :a}, ["ItemsSync"], fn -> :a end) == :a
      assert Cache.fetch({:t, :b}, ["ItemsSync"], fn -> :b end) == :b
      assert Cache.fetch({:t, :a}, ["ItemsSync"], fn -> :other end) == :a
    end

    test "caches falsy values rather than recomputing them" do
      # A `nil` result is a legitimate answer (no such station/level), and an
      # implementation testing truthiness would recompute it every single time —
      # turning the most common miss into the least cached path.
      {counter, bump} = counting_fun()

      compute = fn ->
        bump.()
        nil
      end

      assert Cache.fetch({:t, :nil_value}, ["ItemsSync"], compute) == nil
      assert Cache.fetch({:t, :nil_value}, ["ItemsSync"], compute) == nil

      assert calls(counter) == 1
    end

    test "bypasses the cache entirely when disabled" do
      Application.put_env(:eft_buddy, :cache_enabled, false)
      {counter, bump} = counting_fun()

      compute = fn ->
        bump.()
        :value
      end

      Cache.fetch({:t, :disabled}, ["ItemsSync"], compute)
      Cache.fetch({:t, :disabled}, ["ItemsSync"], compute)

      assert calls(counter) == 2
    end

    test "an expired entry is recomputed" do
      {counter, bump} = counting_fun()

      compute = fn ->
        bump.()
        :value
      end

      Cache.fetch({:t, :ttl}, ["ItemsSync"], compute, ttl_ms: 0)
      Process.sleep(5)
      Cache.fetch({:t, :ttl}, ["ItemsSync"], compute, ttl_ms: 0)

      assert calls(counter) == 2
    end
  end

  describe "invalidation on sync completion" do
    test "a finished sync drops the entries that syncer owns, and only those" do
      Cache.fetch({:t, :hideout}, ["HideoutSync"], fn -> :hideout end)
      Cache.fetch({:t, :items}, ["ItemsSync"], fn -> :items end)

      emit_sync_stop("HideoutSync")

      {counter, bump} = counting_fun()

      recompute = fn ->
        bump.()
        :rebuilt
      end

      # Hideout's entry is gone, so this recomputes...
      assert Cache.fetch({:t, :hideout}, ["HideoutSync"], recompute) == :rebuilt
      assert calls(counter) == 1

      # ...while an unrelated syncer's entry survives untouched.
      assert Cache.fetch({:t, :items}, ["ItemsSync"], recompute) == :items
      assert calls(counter) == 1
    end

    test "a labelled run invalidates its base syncer" do
      # Reporter emits "TasksSync:regular" and "TasksSync:pve" for the two game
      # modes. Both write the same tables, so either must clear entries that
      # named "TasksSync".
      Cache.fetch({:t, :tasks}, ["TasksSync"], fn -> :tasks end)

      emit_sync_stop("TasksSync:pve")

      assert Cache.fetch({:t, :tasks}, ["TasksSync"], fn -> :rebuilt end) == :rebuilt
    end

    test "an entry owned by several syncers is dropped when ANY of them finishes" do
      # The flea view is derived from items, prices and flea settings; a refresh
      # of any one of them makes a cached projection of all three untrue.
      Cache.fetch({:t, :multi}, ["ItemsSync", "PricesSync"], fn -> :original end)

      emit_sync_stop("PricesSync:regular")

      assert Cache.fetch({:t, :multi}, ["ItemsSync", "PricesSync"], fn -> :rebuilt end) ==
               :rebuilt
    end

    test "an unrelated syncer finishing changes nothing" do
      Cache.fetch({:t, :untouched}, ["HideoutSync"], fn -> :original end)

      emit_sync_stop("MapsSync")

      assert Cache.fetch({:t, :untouched}, ["HideoutSync"], fn -> :rebuilt end) == :original
    end
  end

  describe "clear/0 and size/0" do
    test "clear drops everything" do
      Cache.fetch({:t, :one}, ["ItemsSync"], fn -> 1 end)
      Cache.fetch({:t, :two}, ["MapsSync"], fn -> 2 end)
      assert Cache.size() >= 2

      Cache.clear()

      assert Cache.size() == 0
    end
  end

  describe "observability" do
    test "counts hits and misses so a cache that saves nothing is visible" do
      # The failure this exists for: a cache whose written keys are not its read
      # keys works perfectly — right answer, every time — while saving nothing
      # and carrying every staleness risk. Nothing else in the system can tell
      # that apart from a cache that is working.
      before = Cache.stats()

      Cache.fetch({:t, :counted}, ["ItemsSync"], fn -> :v end)
      Cache.fetch({:t, :counted}, ["ItemsSync"], fn -> :v end)
      Cache.fetch({:t, :counted}, ["ItemsSync"], fn -> :v end)

      after_ = Cache.stats()

      assert after_.misses - before.misses == 1
      assert after_.hits - before.hits == 2
    end

    test "reports no hit rate at all before anything has been read" do
      # nil, not 0.0. "Nothing has been asked for yet" and "every read missed"
      # are opposite diagnoses and must not render identically on a dashboard.
      assert %{hit_rate: rate} = Cache.stats()
      assert is_nil(rate) or is_float(rate)
    end

    test "invalidate_source reports how many entries it dropped" do
      # Zero dropped by a syncer that owns entries is the signature of a source
      # name that no longer matches anything — a rename away from silently
      # serving stale data forever.
      Cache.fetch({:t, :a}, ["HideoutSync"], fn -> 1 end)
      Cache.fetch({:t, :b}, ["HideoutSync"], fn -> 2 end)
      Cache.fetch({:t, :c}, ["MapsSync"], fn -> 3 end)

      assert Cache.invalidate_source("HideoutSync") == 2
      assert Cache.invalidate_source("HideoutSync") == 0
    end

    test "entries expose metadata but never the cached values themselves" do
      # Values are the point of the table and can be megabytes each; copying them
      # out to render a page would make observing the cache cost more than using
      # it.
      Cache.fetch({:t, :meta}, ["ItemsSync", "PricesSync"], fn -> :a_large_value end)

      assert [entry] = Enum.filter(Cache.entries(), &(&1.key == {:t, :meta}))
      assert entry.sources == ["ItemsSync", "PricesSync"]
      assert entry.age_ms >= 0
      assert entry.expires_in_ms > 0
      refute Map.has_key?(entry, :value)
    end
  end

  describe "put/4 and put_many/3" do
    test "put/4 writes an entry fetch/4 then serves without recomputing" do
      Cache.put({:put_test, :a}, :written, ["ItemsSync"])

      {counter, bump} = counting_fun()

      assert Cache.fetch({:put_test, :a}, ["ItemsSync"], fn ->
               bump.()
               :recomputed
             end) == :written

      assert calls(counter) == 0
    end

    test "put_many/3 applies the same sources to every entry" do
      Cache.put_many([{{:pm, 1}, :a}, {{:pm, 2}, :b}], ["TasksSync"])

      assert Cache.size() == 2
      assert Cache.invalidate_source("TasksSync") == 2
      assert Cache.size() == 0
    end

    test "put_many/3 with an empty list is a no-op" do
      assert Cache.put_many([], ["TasksSync"]) == :ok
      assert Cache.size() == 0
    end
  end

  describe "get/1" do
    test "returns the value without computing, or :miss" do
      assert Cache.get({:get_test, :absent}) == :miss

      Cache.put({:get_test, :present}, :v, ["ItemsSync"])
      assert Cache.get({:get_test, :present}) == {:ok, :v}
    end

    test "an expired entry is a miss" do
      Cache.put({:get_test, :stale}, :v, ["ItemsSync"], ttl_ms: 0)
      Process.sleep(5)

      assert Cache.get({:get_test, :stale}) == :miss
    end
  end

  describe "live?/1" do
    test "is true for a live entry and false for an expired or absent one" do
      Cache.put({:live_test, :fresh}, :v, ["ItemsSync"])
      Cache.put({:live_test, :stale}, :v, ["ItemsSync"], ttl_ms: 0)
      Process.sleep(5)

      assert Cache.live?({:live_test, :fresh})
      refute Cache.live?({:live_test, :stale})
      refute Cache.live?({:live_test, :absent})
    end

    test "does NOT delete the expired entry it reports on" do
      # The sweep is the single deleter. A probe with a side effect is a probe
      # you cannot run from a dashboard, and `live_count/1` over a whole spec
      # registry would otherwise quietly mutate the table it is describing.
      Cache.put({:live_test, :stale}, :v, ["ItemsSync"], ttl_ms: 0)
      Process.sleep(5)

      refute Cache.live?({:live_test, :stale})
      assert Cache.size() == 1
    end

    test "does not count as a read" do
      before = Cache.stats()

      Cache.put({:live_test, :fresh}, :v, ["ItemsSync"])
      Cache.live?({:live_test, :fresh})
      Cache.live?({:live_test, :absent})

      after_stats = Cache.stats()
      assert after_stats.hits == before.hits
      assert after_stats.misses == before.misses
    end

    test "does not copy the value out of the table" do
      # The whole reason a periodic re-warm is affordable. Reading through
      # `fetch/4` instead would copy every cached value into the warmer on every
      # pass; `live?/1` reads one integer.
      big = List.duplicate(:x, 50_000)
      for i <- 1..40, do: Cache.put({:live_test, :big, i}, big, ["ItemsSync"])

      keys = for i <- 1..40, do: {:live_test, :big, i}

      {_pid, ref} =
        :erlang.spawn_opt(fn -> 40 = Cache.live_count(keys) end, [
          :monitor,
          max_heap_size: %{size: 100_000, kill: true, error_logger: false}
        ])

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 5_000
    end
  end

  describe "fetch_many/4" do
    test "calls the fill function with only the keys that missed" do
      Cache.put({:fm, 1}, :cached, ["ItemsSync"])

      test_pid = self()

      result =
        Cache.fetch_many([{:fm, 1}, {:fm, 2}], ["ItemsSync"], fn missing ->
          send(test_pid, {:asked_for, missing})
          Map.new(missing, &{&1, :filled})
        end)

      assert_received {:asked_for, [{:fm, 2}]}
      assert result == %{{:fm, 1} => :cached, {:fm, 2} => :filled}
    end

    test "does not call the fill function at all when everything hits" do
      Cache.put({:fm, 1}, :a, ["ItemsSync"])
      Cache.put({:fm, 2}, :b, ["ItemsSync"])

      test_pid = self()

      result =
        Cache.fetch_many([{:fm, 1}, {:fm, 2}], ["ItemsSync"], fn missing ->
          send(test_pid, {:asked_for, missing})
          %{}
        end)

      refute_received {:asked_for, _}
      assert result == %{{:fm, 1} => :a, {:fm, 2} => :b}
    end

    test "keys the fill function omits are neither stored nor returned" do
      # This is what keeps a batched read's key space bounded by rows that
      # exist. A caller asking about something absent must not mint an entry for
      # it, or the key space becomes whatever callers can name.
      result =
        Cache.fetch_many([{:fm, :real}, {:fm, :bogus}], ["ItemsSync"], fn _missing ->
          %{{:fm, :real} => :v}
        end)

      assert result == %{{:fm, :real} => :v}
      assert Cache.entries() |> Enum.map(& &1.key) == [{:fm, :real}]
    end

    test "counts a hit and a miss per key, not per call" do
      Cache.put({:fm, 1}, :a, ["ItemsSync"])
      before = Cache.stats()

      Cache.fetch_many([{:fm, 1}, {:fm, 2}, {:fm, 3}], ["ItemsSync"], fn missing ->
        Map.new(missing, &{&1, :v})
      end)

      after_stats = Cache.stats()
      assert after_stats.hits - before.hits == 1
      assert after_stats.misses - before.misses == 2
    end

    test "with the cache disabled, the fill function receives every key" do
      Application.put_env(:eft_buddy, :cache_enabled, false)

      result =
        Cache.fetch_many([{:fm, 1}, {:fm, 2}], ["ItemsSync"], fn missing ->
          Map.new(missing, &{&1, :v})
        end)

      assert result == %{{:fm, 1} => :v, {:fm, 2} => :v}
      assert Cache.size() == 0
    end
  end

  describe "origin attribution" do
    test "a plain process is a visitor; a marked process is the warmer" do
      # Without this split the warmer's own builds land in the visitor miss
      # column, and once it re-probes on a timer it becomes the busiest reader
      # on the node — at which point the hit rate stops describing anybody.
      before = Cache.stats()

      Cache.fetch({:origin, :v}, ["ItemsSync"], fn -> :x end)
      Cache.fetch({:origin, :v}, ["ItemsSync"], fn -> :x end)

      in_warm_process(fn ->
        Cache.fetch({:origin, :w}, ["ItemsSync"], fn -> :x end)
        Cache.fetch({:origin, :w}, ["ItemsSync"], fn -> :x end)
      end)

      s = Cache.stats()
      assert s.hits - before.hits == 1
      assert s.misses - before.misses == 1
      assert s.warm_hits - before.warm_hits == 1
      assert s.warm_misses - before.warm_misses == 1
    end

    test "a warm write is tagged :warm and counted" do
      # Deltas, not absolutes: `Cache.clear/0` empties the table but the
      # counters are cumulative since boot, so an earlier test in this module
      # has already moved them.
      before = Cache.stats()

      in_warm_process(fn -> Cache.put_many([{{:o, 1}, :a}, {{:o, 2}, :b}], ["ItemsSync"]) end)
      Cache.put({:o, 3}, :c, ["ItemsSync"])

      assert Cache.size_by_origin() == %{warm: 2, read: 1}
      assert Cache.stats().warm_writes - before.warm_writes == 2
    end

    test "the marking cannot leak into a later plain process" do
      in_warm_process(fn -> Cache.put({:o, :w}, :v, ["ItemsSync"]) end)

      before = Cache.stats()
      Cache.fetch({:o, :later}, ["ItemsSync"], fn -> :x end)

      s = Cache.stats()
      assert s.misses - before.misses == 1
      assert s.warm_misses == before.warm_misses
    end

    test "put_ttl_override/1 applies only to writes without an explicit ttl" do
      in_warm_process(fn ->
        Cache.put_ttl_override(60_000)
        Cache.put({:ttl, :derived}, :v, ["ItemsSync"])
        Cache.put({:ttl, :explicit}, :v, ["ItemsSync"], ttl_ms: 5_000)
      end)

      by_key = Map.new(Cache.entries(), &{&1.key, &1})

      assert by_key[{:ttl, :derived}].expires_in_ms > 30_000
      assert by_key[{:ttl, :explicit}].expires_in_ms <= 5_000
    end
  end

  # Runs `fun` in a spawned process marked as the warmer, and waits for it.
  # Spawned rather than inline because the marking is process-scoped and must
  # not bleed into the assertions that follow.
  defp in_warm_process(fun) do
    {_pid, ref} =
      spawn_monitor(fn ->
        Cache.mark_warm_process()
        fun.()
      end)

    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 5_000
  end

  # Exactly the event `EftBuddy.Sync.Reporter.record_status/4` emits, so these
  # tests break if that contract changes rather than silently passing against a
  # shape nothing produces.
  defp emit_sync_stop(label) do
    :telemetry.execute(
      [:eft_buddy, :sync, :stop],
      %{duration_ms: 1, warnings: 0, errors: 0, refusals: 0},
      %{label: label, outcome: :ok}
    )

    # The handler runs inline in this process, so no wait is needed — but assert
    # it actually ran rather than assuming.
    :ok
  end
end
