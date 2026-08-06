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
  arbitrary point. When the event does arrive, the TTL never comes into play.

  Belt and braces, deliberately: the mechanism is cheap and the failure it
  guards against is silent.

  Entries written by `EftBuddy.Cache.Warmer` get a TTL derived from their
  owning feed's staleness budget rather than the flat default. A twenty-minute
  expiry is a sensible bound for a ten-minute price feed and a nonsense one for
  a feed that runs daily — there it does not bound staleness, it just guarantees
  the entry spends 23h40m of every cycle cold, which is how most of the warm
  registry came to be expired in production. The bound is still real; it is now
  the same number `/health/sync` reports on.

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

  # Monotonic per-source invalidation counter, one row per source name.
  #
  # A SEPARATE table from `@table` on purpose: these must survive `clear/0`, must
  # not appear in `entries/0`, and must not be walked by `invalidate_source/1`.
  # They are metadata ABOUT the cache rather than cached values.
  @generations :eft_buddy_cache_generations

  # Counters, not an ETS row, and deliberately so: these are incremented on every
  # single read, and `:ets.update_counter` on one hot key serialises writers on
  # that row. `:counters` with `:write_concurrency` gives each scheduler its own
  # slot and sums them on read, which is the right trade when writes vastly
  # outnumber reads of the value.
  #
  # The reference lives in `:persistent_term` because it is written ONCE at boot
  # and never again — a `:persistent_term.put/2` triggers a global GC scan, which
  # is acceptable at startup and would not be at runtime.
  #
  # Reads are counted separately by ORIGIN. A warm build calls `fetch/4` like
  # anything else, so without this split the warmer's own work lands in the
  # visitor miss column — and once the warmer re-probes on a timer it becomes
  # the busiest reader on the node, at which point a single blended hit rate
  # stops describing anybody's experience. `hits`/`misses`/`hit_rate` are
  # therefore VISITORS ONLY; the warm counters are reported beside them.
  @stats_key {__MODULE__, :stats}
  @stat_hits 1
  @stat_misses 2
  @stat_invalidations 3
  @stat_warm_hits 4
  @stat_warm_misses 5
  @stat_warm_writes 6
  @stat_slots 6

  # Deliberately generous. This is the "the invalidation signal never came"
  # bound, not the freshness target — the syncers themselves run on intervals
  # from 10 minutes (flea prices) to 6 hours (the full item pipeline).
  #
  # It is also only the DEFAULT. `EftBuddy.Cache.Warmer` writes warm entries
  # with a TTL derived from their owning feed's staleness budget, because a
  # 20-minute expiry on a 24-hour feed guarantees the entry is cold for 23h40m
  # of every cycle.
  @default_ttl_ms 20 * 60 * 1_000

  # Entry ceiling.
  #
  # Not needed while everything cached was a whole-list read keyed on a game
  # mode — a dozen entries, full stop. It became necessary the moment entries
  # were keyed by ITEM ID: 5,198 items and 1,016 tasks, each detail panel a few
  # tens of KB, is a table that grows with traffic and never shrinks on its own.
  #
  # Eviction is oldest-WRITTEN first among `:read` entries, and skips `:warm`
  # ones entirely — see `enforce_cap/0`.
  @default_max_entries 20_000

  # Process-scoped flags, set by the warmer on each of its short-lived task
  # processes. Neither is an option on `fetch/4`, because the warmer calls
  # CONTEXT functions (`Ammo.list_rounds/0`), not `fetch/4` directly — there is
  # no argument to thread through without pushing cache plumbing into a dozen
  # context signatures. A spawned task cannot leak either flag into a web
  # request.
  @origin_key {__MODULE__, :origin}
  @ttl_override_key {__MODULE__, :ttl_override}

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
          bump(hit_slot())
          value

        :miss ->
          bump(miss_slot())
          value = fun.()
          put(key, value, sources, opts)
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
  Batched `fetch/4`: look up many keys, and call `fun` ONCE with only the ones
  that missed.

  `fun` receives the missing keys and returns `%{key => value}`. It is not
  called at all when everything hit, so a fully warm batch costs zero round
  trips.

  Keys the fill function OMITS are not stored and are absent from the result.
  That is deliberate and load-bearing: it keeps a batched read's key space
  bounded by the rows that actually exist, rather than by whatever the caller
  happened to ask for. A caller asking about a station level that does not
  exist mints nothing.

  This is what lets a per-key cache sit in front of a batched query. Without
  it, code that wants both has to choose between one entry per caller (keyed on
  the whole request, so almost never shared) and one query per key (an N+1).
  """
  def fetch_many(keys, sources, fun, opts \\ [])
      when is_list(keys) and is_list(sources) and is_function(fun, 1) do
    keys = Enum.uniq(keys)

    if enabled?() do
      {hits, misses} =
        Enum.reduce(keys, {%{}, []}, fn key, {hits, misses} ->
          case lookup(key) do
            {:ok, value} -> {Map.put(hits, key, value), misses}
            :miss -> {hits, [key | misses]}
          end
        end)

      bump(hit_slot(), map_size(hits))
      bump(miss_slot(), length(misses))

      case misses do
        [] ->
          hits

        misses ->
          filled = fun.(Enum.reverse(misses))
          put_many(Map.to_list(filled), sources, opts)
          Map.merge(hits, filled)
      end
    else
      fun.(keys)
    end
  end

  @doc """
  Write one entry directly, without a compute function.

  Public because the warmer writes entries it did not read: a bulk builder
  produces thousands of values from one query set and has nothing to `fetch/4`
  against.
  """
  def put(key, value, sources, opts \\ []) when is_list(sources) and is_list(opts) do
    if table_exists?() do
      now = now_ms()
      origin = origin()

      :ets.insert(@table, {key, value, now, now + ttl_for(opts), sources, origin})
      if origin == :warm, do: bump(@stat_warm_writes)

      enforce_cap()
    end

    :ok
  end

  @doc """
  Write many entries in one `:ets.insert/2`.

  `entries` is a `[{key, value}]` list; every entry shares `sources` and the
  TTL. One insert and — more importantly — ONE cap enforcement for the whole
  batch. Writing 10,898 detail panels through `put/4` would run the cap's
  select-and-sort 10,898 times.
  """
  def put_many(entries, sources, opts \\ [])

  def put_many([], _sources, _opts), do: :ok

  def put_many(entries, sources, opts) when is_list(entries) and is_list(sources) do
    if table_exists?() do
      now = now_ms()
      expires_at = now + ttl_for(opts)
      origin = origin()

      rows =
        Enum.map(entries, fn {key, value} -> {key, value, now, expires_at, sources, origin} end)

      :ets.insert(@table, rows)
      if origin == :warm, do: bump(@stat_warm_writes, length(rows))

      enforce_cap()
    end

    :ok
  end

  @doc """
  How many entries a bulk builder should write per `put_many/3` call.

  Lives here rather than in each builder so the three of them cannot drift.
  Chunking bounds the transient allocation of building the row list, and lets a
  build be interrupted at a chunk boundary with everything written so far still
  valid — every entry is self-contained, so a partial build is a correct partial
  build.

  Note it does NOT relieve the connection pool: by the time a builder is
  fanning out, its query has already returned and no database work is in
  flight. Pool pressure is handled by running heavy warm specs strictly
  serially (`EftBuddy.Cache.Warmer`).
  """
  def warm_chunk_size, do: 500

  @doc """
  Pause between bulk-write chunks, in milliseconds.

  Yields the scheduler and gives the garbage collector a window between
  allocations. Warming is work done ahead of a request that has not arrived, so
  wall-clock here is the cheapest thing to spend.
  """
  def warm_chunk_pause_ms, do: 50

  @doc """
  Read without computing. `:miss` when the key is absent or expired.

  Counts as a read, so a caller using this instead of `fetch/4` still shows up
  in the hit rate.
  """
  def get(key) do
    if enabled?() do
      case lookup(key) do
        {:ok, value} ->
          bump(hit_slot())
          {:ok, value}

        :miss ->
          bump(miss_slot())
          :miss
      end
    else
      :miss
    end
  end

  @doc """
  Whether `key` has a live entry, WITHOUT copying its value out of the table.

  `:ets.lookup_element/4` on the expiry field only, so probing a ten-megabyte
  entry costs reading one integer. That is what makes a periodic re-warm
  affordable: the alternative is calling the read and letting `fetch/4` hit,
  which copies every cached value into the warmer on every single pass.

  Deliberately does NOT delete an expired entry, unlike `lookup/1`. The sweep
  is the only deleter — a probe with a side effect is a probe you cannot safely
  run from a dashboard.

  Does not count as a read. Probing is not using.
  """
  def live?(key) do
    table_exists?() and
      case :ets.lookup_element(@table, key, 4, nil) do
        nil -> false
        expires_at -> now_ms() < expires_at
      end
  end

  @doc "How many of `keys` are live. Same no-copy guarantee as `live?/1`."
  def live_count(keys) when is_list(keys), do: Enum.count(keys, &live?/1)

  @doc """
  The TTL applied to an entry written without an explicit `:ttl_ms`.

  Public because `EftBuddy.Cache.Warmer` derives its repair interval from it. A
  warmer ticking on one hard-coded number while the cache expires on another is
  precisely the drift that left 5 of 19 warm specs live in production.
  """
  def default_ttl_ms, do: Application.get_env(:eft_buddy, :cache_ttl_ms, @default_ttl_ms)

  @doc """
  Marks the calling process as the warmer, so every read it makes is attributed
  to the warm counters rather than to visitors, and every write it makes is
  tagged `:warm` and becomes exempt from cap eviction.

  Set once per warm task process; see the note on `@origin_key`.
  """
  def mark_warm_process do
    Process.put(@origin_key, :warm)
    :ok
  end

  @doc """
  Sets the TTL every write from THIS process will use when no explicit
  `:ttl_ms` is given.

  The warmer calls context functions, which call `fetch/4` with their own
  opts — so this is the only place a per-spec TTL can be injected without
  every context function growing a TTL argument it has no opinion about.
  """
  def put_ttl_override(ms) when is_integer(ms) and ms >= 0 do
    Process.put(@ttl_override_key, ms)
    :ok
  end

  @doc """
  Drops every entry owned by `source`. Called on sync completion.

  Returns the number of entries dropped, which is what makes an invalidation
  observable: "TasksSync finished and evicted 0 entries" is the signature of a
  source name that no longer matches anything, and that failure is otherwise
  completely silent.
  """
  def invalidate_source(source) when is_binary(source) do
    # Bumped BEFORE the scan and regardless of how many entries are dropped.
    #
    # The generation records that the source's DATA changed, not that entries were
    # evicted, and the case it exists for is a bulk build whose first chunk has not
    # landed yet: `dropped` is legitimately 0 there, and the build is nonetheless
    # about to write a set derived from data that has since moved. Gating on
    # `dropped > 0` would miss exactly that.
    bump_generation(source)

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
        |> :ets.select([{{:"$1", :_, :_, :_, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
        |> Enum.count(fn {key, sources} ->
          source in sources and :ets.delete(@table, key)
        end)
      else
        0
      end

    if dropped > 0, do: bump(@stat_invalidations, dropped)

    dropped
  end

  @doc """
  Drops the given keys. Returns how many existed.

  For a bulk builder unwinding its own partial work — a half-written set that
  stays in the table is memory spent on entries whose build already decided it
  should not have spent it.
  """
  def drop(keys) when is_list(keys) do
    if table_exists?() do
      Enum.count(keys, &:ets.delete(@table, &1))
    else
      0
    end
  end

  @doc """
  How many times `source` has invalidated since boot.

  Exists so a long-running bulk build can tell whether the data underneath it
  changed while it ran. `stats().invalidations` cannot answer that: it is global,
  it counts ENTRIES rather than events, and the ten-minute price feed moves it
  during essentially every multi-minute build — so a build gated on it would never
  record coverage at all, and the repair tick would rebuild the largest sets in
  the registry every five minutes forever.
  """
  def generation(source) when is_binary(source) do
    case :ets.lookup(@generations, source) do
      [{^source, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Generations for several sources at once, as `%{source => n}`."
  def generations(sources) when is_list(sources),
    do: Map.new(sources, &{&1, generation(&1)})

  @doc """
  Drops everything. Used by tests and available from a remote console.

  Deliberately leaves the generation counters alone: monotonicity is the whole
  point of them, and a reset can only ever cause a CONSERVATIVE mismatch — a
  build that compares 7 against 0 withholds its sentinel and rebuilds, which
  costs work and never correctness. The same reasoning covers a supervisor
  restart of this GenServer.
  """
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
      |> :ets.select([
        {{:"$1", :_, :"$2", :"$3", :"$4", :"$5"}, [], [{{:"$1", :"$2", :"$3", :"$4", :"$5"}}]}
      ])
      |> Enum.map(fn {key, inserted_at, expires_at, sources, origin} ->
        %{
          key: key,
          sources: sources,
          origin: origin,
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
  Cumulative read / invalidation counts since boot, plus the derived hit rate.

  `hits`, `misses` and `hit_rate` count **visitor reads only**. That is a change
  of meaning from an earlier version where they counted every read, and it is
  the point: a warm build calls `fetch/4` and misses, so the warmer's own work
  landed in the miss column — and once warming re-probes on a timer, the warmer
  becomes the busiest reader on the node. A blended rate would then answer "is
  the warmer hitting its own entries", which is not a question anyone has.

  The warm counters are reported alongside, and they read **inversely** to the
  visitor ones: with the warmer's liveness probe working, `warm_hits` should sit
  near zero, because the warmer should almost never be reading something it
  already has. A high warm hit rate means the probe is failing to skip.

  The hit rate remains the number that matters. A cache with a low one is not
  saving round trips, it is adding a lookup to every read and a whole class of
  staleness bug for nothing — and without this that would be invisible, because
  a badly-keyed cache behaves *correctly* in every respect except the one it
  exists for.
  """
  def stats do
    {hits, misses, invalidations, warm_hits, warm_misses, warm_writes} =
      case :persistent_term.get(@stats_key, nil) do
        nil ->
          {0, 0, 0, 0, 0, 0}

        ref ->
          {:counters.get(ref, @stat_hits), :counters.get(ref, @stat_misses),
           :counters.get(ref, @stat_invalidations), :counters.get(ref, @stat_warm_hits),
           :counters.get(ref, @stat_warm_misses), :counters.get(ref, @stat_warm_writes)}
      end

    reads = hits + misses
    by_origin = size_by_origin()

    %{
      hits: hits,
      misses: misses,
      invalidations: invalidations,
      warm_hits: warm_hits,
      warm_misses: warm_misses,
      warm_writes: warm_writes,
      # nil rather than 0 when nothing has been read yet: "no data" and "every
      # read missed" are opposite diagnoses and must not render identically.
      hit_rate: if(reads > 0, do: hits / reads, else: nil),
      entries: size(),
      warm_entries: by_origin.warm,
      read_entries: by_origin.read,
      max_entries: max_entries(),
      memory_bytes: memory_bytes(),
      enabled: enabled?()
    }
  end

  @doc """
  Entry counts split by who wrote them.

  Makes ceiling pressure legible: `read` is the only part eviction can reclaim,
  so `warm` approaching `max_entries` is the signal to raise the ceiling before
  `enforce_cap/0` starts logging that it cannot.
  """
  def size_by_origin do
    if table_exists?() do
      warm = :ets.select_count(@table, [{{:_, :_, :_, :_, :_, :warm}, [], [true]}])
      %{warm: warm, read: :ets.info(@table, :size) - warm}
    else
      %{warm: 0, read: 0}
    end
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
        warm_entries: s.warm_entries,
        read_entries: s.read_entries,
        warm_hits: s.warm_hits,
        warm_misses: s.warm_misses,
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
        [{^key, value, _inserted_at, expires_at, _sources, _origin}] ->
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

  defp origin, do: Process.get(@origin_key, :read)

  defp hit_slot, do: if(origin() == :warm, do: @stat_warm_hits, else: @stat_hits)
  defp miss_slot, do: if(origin() == :warm, do: @stat_warm_misses, else: @stat_misses)

  defp ttl_for(opts) do
    Keyword.get_lazy(opts, :ttl_ms, fn ->
      Process.get(@ttl_override_key) || default_ttl_ms()
    end)
  end

  defp enforce_cap do
    max = max_entries()
    size = :ets.info(@table, :size)

    if size > max do
      # Only `:read` entries are eligible. Warm entries are the precomputed set
      # the server builds on purpose; their count is bounded by the game's
      # content rather than by traffic, so evicting them to honour a ceiling
      # chosen by guesswork would throw away exactly the work this cache exists
      # to do — and silently, since the reads would still return correct
      # answers, just slowly.
      #
      # This replaces an argument that was wrong in practice: the old comment
      # justified oldest-written eviction by saying warm entries "continuously
      # renew their position" because the warmer rewrites them every sync. With
      # feeds running every 6 to 24 hours they do not renew; they are
      # permanently the OLDEST rows in the table, and were therefore the first
      # thing evicted under detail-panel traffic.
      #
      # Select only `{inserted_at, key}` — never whole objects. The values are
      # the expensive part of this table and must not be copied out merely to
      # decide which ones to drop.
      evictable =
        :ets.select(@table, [
          {{:"$1", :_, :"$2", :_, :_, :read}, [], [{{:"$2", :"$1"}}]}
        ])

      needed = evictions_needed(size, max)

      evictable
      |> Enum.sort()
      |> Enum.take(needed)
      |> Enum.each(fn {_inserted_at, key} -> :ets.delete(@table, key) end)

      if length(evictable) < needed do
        # Overshoot rather than evict warm entries, and say so loudly enough to
        # act on. A silent overshoot looks like the ceiling working.
        Logger.error("""
        [Cache] over the #{max}-entry ceiling with #{size} entries, of which \
        only #{length(evictable)} are evictable request-driven reads. The warm \
        set alone exceeds the ceiling — raise :cache_max_entries (env \
        CACHE_MAX_ENTRIES) above the number of entries the warmer builds.\
        """)
      end
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
        {{:_, :_, :_, :"$1", :_, :_}, [{:<, :"$1", now_ms()}], [true]}
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

  # `update_counter/4` with a default, so the first invalidation for a source
  # creates its row rather than needing an existence check first.
  defp bump_generation(source) do
    :ets.update_counter(@generations, source, {2, 1}, {source, 0})
  rescue
    ArgumentError -> 0
  end

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

    :ets.new(@generations, [:set, :named_table, :public, write_concurrency: true])

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
