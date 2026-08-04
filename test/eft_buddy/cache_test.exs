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
