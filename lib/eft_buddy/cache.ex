defmodule EftBuddy.Cache do
  @moduledoc """
  In-memory read cache for data that only changes when a syncer writes it.

  ## Why this exists

  Every query to the hosted database costs about 76ms, because that is the
  round-trip time to the region it runs in. The query itself is trivial; the
  distance is not. A page issuing twenty queries therefore spends about a second
  waiting on the network before it renders anything, and the VM sits at 2% CPU
  the whole time — the app is not slow, it is *far away*.

  Almost nothing this app serves is per-request data. Items, tasks, hideout
  stations, maps, ammo and the wiki scrapes change only when a syncer runs, which
  is every few hours for most feeds. Re-reading them across the internet on every
  page view pays the full latency to return bytes that have not changed since the
  last sync.

  ## Freshness is not traded away

  A cache entry is dropped the moment the syncer that owns its data finishes, via
  the `[:eft_buddy, :sync, :stop]` telemetry event `EftBuddy.Sync.Reporter`
  already emits. So a cached read is exactly as current as an uncached one: both
  return what the last sync wrote. What changes is only how many times that
  answer is fetched over the wire.

  This is worth stating plainly because it is counter-intuitive: skipping the
  cache does not give fresher data. It gives fresher *reads* of equally old data.
  The freshness ceiling is the sync interval, and no amount of cache avoidance
  raises it.

  ## The TTL is a backstop, not the mechanism

  Invalidation is by sync completion. The TTL exists only for the case where that
  signal never arrives — a syncer that crashes before emitting, a telemetry
  handler detached by a bug, a feed quietly wedged. Without it, a cache keyed
  purely on an event that stops firing serves the same answer forever, and the
  failure is invisible: the page keeps rendering, just with data frozen at an
  arbitrary point. The TTL bounds that to 20 minutes. When the event does
  arrive, the TTL never comes into play.

  Belt and braces, deliberately: the mechanism is cheap and the failure it
  guards against is silent.

  ## What is safe to cache here

  Only functions whose result depends on nothing but the database — no operator
  token, no per-request filters. `EftBuddy.Items.list_flea_market_items/1` takes
  `favorite_slugs` and `pmc_level`, so caching its *result* would mean one entry
  per user per filter combination: unbounded, and mostly missed. Data like that
  needs the dataset cached and the filtering done in memory, which is a different
  change from this one.

  ## Scope

  Per-node, in memory. This app runs a single instance, so that is the whole
  story. On two nodes each would hold its own copy and they could briefly
  disagree after a sync, since the telemetry event is local.
  """

  use GenServer

  require Logger

  @table :eft_buddy_cache
  @sync_event [:eft_buddy, :sync, :stop]

  # Counters, not an ETS row, and deliberately so: these are incremented on every
  # single read, and `:ets.update_counter` on one hot key serialises writers on
  # that row. `:counters` with `:write_concurrency` gives each scheduler its own
  # slot and sums them on read, which is the right trade when writes vastly
  # outnumber reads of the value.
  #
  # The reference lives in `:persistent_term` because it is written ONCE at boot
  # and never again — a `:persistent_term.put/2` triggers a global GC scan, which
  # is acceptable at startup and would not be at runtime.
  @stats_key {__MODULE__, :stats}
  @stat_hits 1
  @stat_misses 2
  @stat_invalidations 3
  @stat_slots 3

  # Deliberately generous. This is the "the invalidation signal never came"
  # bound, not the freshness target — the syncers themselves run on intervals
  # from 10 minutes (flea prices) to 6 hours (the full item pipeline).
  @default_ttl_ms 20 * 60 * 1_000

  # Entry ceiling.
  #
  # Not needed while everything cached was a whole-list read keyed on a game
  # mode — a dozen entries, full stop. It became necessary the moment entries
  # were keyed by ITEM ID: 5,198 items and 1,016 tasks, each detail panel a few
  # tens of KB, is a table that grows with traffic and never shrinks on its own.
  #
  # Eviction is oldest-WRITTEN first, which is not true LRU. It is the right
  # approximation here because the entries worth keeping are the whole-list ones,
  # and those are rewritten by the warmer on every sync — so they continuously
  # renew their position while a detail panel opened once and never revisited
  # ages out. Say so plainly rather than calling this an LRU.
  @default_max_entries 2_000

  # Expiry is otherwise LAZY — an entry past its TTL is only noticed when someone
  # reads that exact key. For the whole-list entries that is fine, since they get
  # read constantly. For id-keyed entries it is not: a detail panel opened once
  # would hold its memory forever, expired and unreachable, because nothing ever
  # looks that key up again.
  @sweep_interval_ms 60 * 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the cached value for `key`, or computes it with `fun` and stores it.

  `sources` names the syncers whose completion invalidates this entry, matching
  the labels `EftBuddy.Sync.Reporter` emits (`"ItemsSync"`, `"HideoutSync"`, …).
  A value derived from several feeds lists all of them and is dropped when any
  one finishes.

  Passing `[]` for `sources` means the entry is only ever evicted by its TTL. That
  is almost always a mistake — prefer naming the syncer.
  """
  def fetch(key, sources, fun, opts \\ []) when is_list(sources) and is_function(fun, 0) do
    if enabled?() do
      case lookup(key) do
        {:ok, value} ->
          bump(@stat_hits)
          value

        :miss ->
          bump(@stat_misses)
          value = fun.()
          put(key, value, sources, Keyword.get(opts, :ttl_ms, @default_ttl_ms))
          value
      end
    else
      # Disabled in test (see config/test.exs): a suite that inserts a row and
      # immediately reads it back must not be served a value cached by an earlier
      # test. The cache has its own tests, which enable it explicitly.
      fun.()
    end
  end

  @doc """
  Drops every entry owned by `source`. Called on sync completion.

  Returns the number of entries dropped, which is what makes an invalidation
  observable: "TasksSync finished and evicted 0 entries" is the signature of a
  source name that no longer matches anything, and that failure is otherwise
  completely silent.
  """
  def invalidate_source(source) when is_binary(source) do
    dropped =
      if table_exists?() do
        # Still a full scan — match specs cannot express "this list contains
        # that element", so ownership has to be tested in Elixir. But the scan
        # selects only `{key, sources}`: the VALUES never cross into this
        # process.
        #
        # That distinction is the whole point. This runs inside the telemetry
        # handler, which runs on the SYNCER'S OWN PROCESS, and the table now
        # holds thousands of precomputed detail payloads. A `tab2list/1` here
        # would copy every one of them onto a syncer's heap on every single
        # sync completion. An earlier version of this function did exactly
        # that, under a comment reasoning that the table "holds tens of
        # entries, not millions" — true when it was written, and the warming
        # work invalidated it.
        @table
        |> :ets.select([{{:"$1", :_, :_, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.count(fn {key, sources} ->
          source in sources and :ets.delete(@table, key)
        end)
      else
        0
      end

    if dropped > 0, do: bump(@stat_invalidations, dropped)

    dropped
  end

  @doc "Drops everything. Used by tests and available from a remote console."
  def clear do
    if table_exists?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Entry count, for the dashboard and for tests."
  def size do
    if table_exists?(), do: :ets.info(@table, :size), else: 0
  end

  @doc """
  Bytes the table occupies, from `:ets.info/2`.

  This is O(1). Summing `:erts_debug.flat_size/1` per entry would be more
  precise but has to walk every term — which is fine for a handful of small
  entries and emphatically not fine once something multi-megabyte is cached,
  where it would make merely *looking* at the dashboard expensive.
  """
  def memory_bytes do
    case table_exists?() do
      true -> :ets.info(@table, :memory) * :erlang.system_info(:wordsize)
      false -> 0
    end
  end

  @doc """
  Per-entry metadata — key, owning syncers, age and time left — for the
  operator dashboard.

  Deliberately excludes the cached **values**. They are the entire point of the
  table and can be megabytes each; copying them out to render a page would make
  observing the cache more expensive than using it.

  The exclusion has to happen in the MATCH SPEC, not in the `Enum.map/2` that
  builds these maps. Dropping the value after `:ets.tab2list/1` has already
  copied it is not an exclusion at all — it just makes the garbage collector,
  rather than the map, responsible for hundreds of megabytes on every dashboard
  render.
  """
  def entries do
    if table_exists?() do
      now = now_ms()

      @table
      |> :ets.select([{{:"$1", :_, :"$2", :"$3", :"$4"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}])
      |> Enum.map(fn {key, inserted_at, expires_at, sources} ->
        %{
          key: key,
          sources: sources,
          age_ms: now - inserted_at,
          expires_in_ms: expires_at - now
        }
      end)
      |> Enum.sort_by(& &1.age_ms)
    else
      []
    end
  end

  @doc """
  Cumulative hit / miss / invalidation counts since boot, plus the derived hit
  rate.

  The number that matters is the hit rate. A cache with a low one is not saving
  round trips, it is adding a lookup to every read and a whole class of
  staleness bug for nothing — and without this that would be invisible, because
  a badly-keyed cache behaves *correctly* in every respect except the one it
  exists for.
  """
  def stats do
    {hits, misses, invalidations} =
      case :persistent_term.get(@stats_key, nil) do
        nil ->
          {0, 0, 0}

        ref ->
          {:counters.get(ref, @stat_hits), :counters.get(ref, @stat_misses),
           :counters.get(ref, @stat_invalidations)}
      end

    reads = hits + misses

    %{
      hits: hits,
      misses: misses,
      invalidations: invalidations,
      # nil rather than 0 when nothing has been read yet: "no data" and "every
      # read missed" are opposite diagnoses and must not render identically.
      hit_rate: if(reads > 0, do: hits / reads, else: nil),
      entries: size(),
      memory_bytes: memory_bytes(),
      enabled: enabled?()
    }
  end

  def enabled?, do: Application.get_env(:eft_buddy, :cache_enabled, true)

  @doc false
  # Invoked by `:telemetry_poller` (see `EftBuddyWeb.Telemetry`).
  #
  # Polled rather than event-driven for the same reason sync freshness is: the
  # interesting states here are ones where nothing happens. A cache whose hit
  # rate has collapsed emits no event — it just quietly stops helping — and an
  # entry count stuck at zero after a sync means invalidation is firing and
  # warming is not. Neither is visible from events alone.
  def emit_telemetry do
    s = stats()

    :telemetry.execute(
      [:eft_buddy, :cache, :state],
      %{
        entries: s.entries,
        memory_bytes: s.memory_bytes,
        hits: s.hits,
        misses: s.misses,
        # Percent, so it charts as an integer-ish gauge rather than a float
        # between 0 and 1 that reads as "always zero" at a glance.
        hit_rate_percent: if(s.hit_rate, do: round(s.hit_rate * 100), else: 0)
      },
      %{enabled: s.enabled}
    )
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp lookup(key) do
    if table_exists?() do
      case :ets.lookup(@table, key) do
        [{^key, value, _inserted_at, expires_at, _sources}] ->
          if now_ms() < expires_at do
            {:ok, value}
          else
            :ets.delete(@table, key)
            :miss
          end

        [] ->
          :miss
      end
    else
      :miss
    end
  end

  defp put(key, value, sources, ttl_ms) do
    if table_exists?() do
      now = now_ms()
      :ets.insert(@table, {key, value, now, now + ttl_ms, sources})
      enforce_cap()
    end

    :ok
  end

  defp enforce_cap do
    max = max_entries()
    size = :ets.info(@table, :size)

    if size > max do
      # Select only `{inserted_at, key}` rather than whole objects: the values
      # are the expensive part of this table and must not be copied out merely
      # to decide which ones to drop.
      @table
      |> :ets.select([{{:"$1", :_, :"$2", :_, :_}, [], [{{:"$2", :"$1"}}]}])
      |> Enum.sort()
      |> Enum.take(evictions_needed(size, max))
      |> Enum.each(fn {_inserted_at, key} -> :ets.delete(@table, key) end)
    end
  end

  # Evict a BATCH rather than one-per-insert, so a table sitting exactly at the
  # ceiling does not pay a full scan on every single write — but never fewer
  # than it takes to get back under the ceiling.
  #
  # The flat 10% this replaced was correct only while every write was a single
  # `fetch/4` miss, which can put the table at most one entry over. A bulk warm
  # inserts thousands at once, and a fixed 10% would then leave the table over
  # the ceiling after a full scan-and-sort — repeated on the next write, and
  # the next.
  defp evictions_needed(size, max), do: max(size - max, div(max, 10))

  defp sweep_expired do
    if table_exists?() do
      # A match spec, so expired entries are deleted without any of their values
      # crossing into this process.
      :ets.select_delete(@table, [
        {{:_, :_, :_, :"$1", :_}, [{:<, :"$1", now_ms()}], [true]}
      ])
    else
      0
    end
  end

  defp max_entries,
    do: Application.get_env(:eft_buddy, :cache_max_entries, @default_max_entries)

  # Writes go straight to ETS from the calling process rather than through the
  # GenServer, so a slow reader can never queue behind another one. The GenServer
  # exists to own the table's lifetime and the telemetry handler, not to serialise
  # access.
  #
  # Two processes missing on the same key will both compute it and the second
  # write wins. That is a duplicated read, not a correctness problem, and adding
  # per-key locking would cost more than the occasional double fetch.
  defp table_exists?, do: :ets.whereis(@table) != :undefined

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp bump(slot, by \\ 1) do
    case :persistent_term.get(@stats_key, nil) do
      nil -> :ok
      ref -> :counters.add(ref, slot, by)
    end
  end

  # Idempotent. A `:persistent_term.put/2` forces a global GC scan, so a
  # supervisor restart of this GenServer must not pay for one again.
  defp ensure_stats do
    case :persistent_term.get(@stats_key, nil) do
      nil -> :persistent_term.put(@stats_key, :counters.new(@stat_slots, [:write_concurrency]))
      _ref -> :ok
    end
  end

  @impl true
  def init(_opts) do
    ensure_stats()

    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    :telemetry.attach(
      {__MODULE__, :invalidate},
      @sync_event,
      &__MODULE__.handle_sync_stop/4,
      nil
    )

    schedule_sweep()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    swept = sweep_expired()

    if swept > 0 do
      Logger.debug("[Cache] swept #{swept} expired entries")
    end

    schedule_sweep()

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @doc false
  # Labels arrive as "TasksSync" or "TasksSync:regular" — the suffix is a per-run
  # variant (game mode), and both write the same tables, so the prefix is what
  # ownership is keyed on.
  #
  # WRAPPED IN try/rescue, and this is the single most important defensive line
  # in the module. `:telemetry` DETACHES a handler that raises, permanently and
  # with only a log line to show for it. This handler *is* the invalidation
  # mechanism, so an exception here would silently demote the whole cache to its
  # 20-minute TTL — the exact failure the TTL exists to bound, arrived at through
  # the mechanism meant to prevent it. Better to drop one invalidation and keep
  # the handler than to lose every future one.
  def handle_sync_stop(@sync_event, _measurements, %{label: label}, _config)
      when is_binary(label) do
    source = label |> String.split(":", parts: 2) |> hd()
    dropped = invalidate_source(source)

    :telemetry.execute(
      [:eft_buddy, :cache, :invalidated],
      %{entries: dropped},
      %{source: source}
    )

    :ok
  rescue
    e ->
      Logger.error("[Cache] invalidation for #{inspect(label)} failed: #{Exception.message(e)}")
      :ok
  end

  def handle_sync_stop(_event, _measurements, _metadata, _config), do: :ok
end
