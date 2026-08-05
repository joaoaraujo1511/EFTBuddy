defmodule EftBuddy.CacheBoundsTest do
  @moduledoc """
  The cache was safe without bounds for as long as everything in it was a
  whole-list read keyed on a game mode — a dozen entries, and every one of them
  read constantly enough that lazy expiry was sufficient.

  Keying entries by item and task id changed both properties at once. The key
  space became the catalogue, and most of those keys are read once and never
  again — so an expired entry is never *noticed* to be expired, and holds its
  memory until the process restarts. These are the two bounds that make that
  safe, tested at the boundary rather than trusted.
  """
  use ExUnit.Case, async: false

  alias EftBuddy.Cache

  setup do
    original_enabled = Application.get_env(:eft_buddy, :cache_enabled)
    original_max = Application.get_env(:eft_buddy, :cache_max_entries)

    Application.put_env(:eft_buddy, :cache_enabled, true)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      Application.put_env(:eft_buddy, :cache_enabled, original_enabled)

      if original_max do
        Application.put_env(:eft_buddy, :cache_max_entries, original_max)
      else
        Application.delete_env(:eft_buddy, :cache_max_entries)
      end
    end)

    :ok
  end

  describe "entry ceiling" do
    test "an id-keyed read cannot grow the table without limit" do
      Application.put_env(:eft_buddy, :cache_max_entries, 50)

      # Ten times the ceiling, which is what "every visitor opens a different
      # item panel" looks like over an afternoon.
      for i <- 1..500 do
        Cache.fetch({:bounds_test, i}, ["ItemsSync"], fn -> i end)
      end

      assert Cache.size() <= 50,
             "table grew to #{Cache.size()} against a ceiling of 50"
    end

    test "eviction keeps the most recently written entries" do
      Application.put_env(:eft_buddy, :cache_max_entries, 20)

      for i <- 1..200 do
        Cache.fetch({:bounds_test, i}, ["ItemsSync"], fn -> i end)
      end

      keys = Cache.entries() |> Enum.map(& &1.key)

      # Oldest-written first. Not true LRU, and deliberately so: the entries
      # worth keeping are the whole-list ones, which the warmer rewrites on every
      # sync and which therefore keep renewing their position.
      refute {:bounds_test, 1} in keys
      assert {:bounds_test, 200} in keys
    end

    test "eviction never copies cached values out of the table" do
      # Guards the match-spec select in `enforce_cap/0`. If it ever regresses to
      # `tab2list`, every eviction would copy every cached value — including,
      # after the dataset layer lands, tens of megabytes — to decide which small
      # keys to delete.
      Application.put_env(:eft_buddy, :cache_max_entries, 10)

      fill_with_big_values(40)

      assert Cache.size() <= 10

      assert_no_value_copy(fn ->
        Cache.fetch({:bounds_test, :big, 99}, ["ItemsSync"], fn -> 1 end)
      end)
    end

    test "an over-ceiling insert gets back under in a single pass" do
      # The flat 10% this replaced could not: a bulk write that overshoots by
      # more than a tenth of the ceiling would stay over after a full
      # scan-and-sort, and stay over on the next write too.
      Application.put_env(:eft_buddy, :cache_max_entries, 20)

      for i <- 1..200 do
        Cache.fetch({:bounds_test, i}, ["ItemsSync"], fn -> i end)
      end

      assert Cache.size() <= 20
    end
  end

  describe "no operation copies cached values into the caller" do
    # These are the reason the whole table can hold thousands of precomputed
    # detail payloads. Both operations below run somewhere a multi-hundred-MB
    # copy would be a real incident: `invalidate_source/1` on the SYNCER'S OWN
    # process (via the telemetry handler), and `entries/0` on every render of
    # the operator dashboard.
    #
    # Asserting on `Cache.size()` would not catch a regression here — the
    # results are correct either way. So instead each operation runs in a
    # process with a HARD HEAP CEILING: copying the values out cannot fit under
    # it, so a regression to `tab2list` kills the process and fails the test,
    # while the match-spec version stays kilobytes wide.

    test "invalidate_source/1 selects keys and sources, not values" do
      fill_with_big_values(40)

      assert_no_value_copy(fn -> Cache.invalidate_source("ItemsSync") end)
    end

    test "entries/0 selects metadata, not values" do
      fill_with_big_values(40)

      assert_no_value_copy(fn -> Cache.entries() end)
    end
  end

  describe "expiry sweep" do
    test "an entry nobody reads again still stops occupying the table" do
      # The id-keyed failure mode precisely: expiry is lazy, so a detail panel
      # opened once is never looked up again and its expired entry would sit
      # there until the node restarted.
      Cache.fetch({:bounds_test, :abandoned}, ["ItemsSync"], fn -> :v end, ttl_ms: 0)
      # Monotonic time is millisecond-resolution and this test is faster than
      # that, so without a beat the entry's expiry can equal the sweep's "now"
      # and the strict `<` correctly does not fire.
      Process.sleep(5)

      assert Cache.size() == 1

      send(Process.whereis(Cache), :sweep)

      # A `call` after the `send` proves the cast was processed, without sleeping.
      _ = :sys.get_state(Cache)

      assert Cache.size() == 0
    end

    test "the sweep leaves live entries alone" do
      Cache.fetch({:bounds_test, :live}, ["ItemsSync"], fn -> :v end)
      Cache.fetch({:bounds_test, :dead}, ["ItemsSync"], fn -> :v end, ttl_ms: 0)
      # Monotonic time is millisecond-resolution and this test is faster than
      # that, so without a beat the entry's expiry can equal the sweep's "now"
      # and the strict `<` correctly does not fire.
      Process.sleep(5)

      send(Process.whereis(Cache), :sweep)
      _ = :sys.get_state(Cache)

      assert Cache.entries() |> Enum.map(& &1.key) == [{:bounds_test, :live}]
    end
  end

  # 40 entries of ~50k words each. Copying them all is ~2M words; the heap
  # ceiling below is 100k, so any implementation that copies dies and any
  # implementation that selects only keys/sources/metadata is nowhere near it.
  defp fill_with_big_values(count) do
    big = List.duplicate(:x, 50_000)

    for i <- 1..count do
      Cache.fetch({:bounds_test, :big, i}, ["ItemsSync"], fn -> big end)
    end
  end

  defp assert_no_value_copy(fun) do
    {_pid, ref} =
      :erlang.spawn_opt(fun, [
        :monitor,
        max_heap_size: %{size: 100_000, kill: true, error_logger: false}
      ])

    receive do
      {:DOWN, ^ref, :process, _pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        flunk("""
        the operation exceeded a 100k-word heap, which means it copied cached \
        values out of the table. Exit reason: #{inspect(reason)}
        """)
    after
      5_000 -> flunk("the operation did not finish within 5s")
    end
  end
end
