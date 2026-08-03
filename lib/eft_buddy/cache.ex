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

  # Deliberately generous. This is the "the invalidation signal never came"
  # bound, not the freshness target — the syncers themselves run on intervals
  # from 10 minutes (flea prices) to 6 hours (the full item pipeline).
  @default_ttl_ms 20 * 60 * 1_000

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
          value

        :miss ->
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

  @doc "Drops every entry owned by `source`. Called on sync completion."
  def invalidate_source(source) when is_binary(source) do
    if table_exists?() do
      # A full scan, not a match spec: match specs cannot express "this list
      # contains that element", and the table holds tens of entries, not
      # millions. Simplicity wins at this size.
      @table
      |> :ets.tab2list()
      |> Enum.each(fn {key, _value, _expires_at, sources} ->
        if source in sources, do: :ets.delete(@table, key)
      end)
    end

    :ok
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

  def enabled?, do: Application.get_env(:eft_buddy, :cache_enabled, true)

  # ── internals ──────────────────────────────────────────────────────────────

  defp lookup(key) do
    if table_exists?() do
      case :ets.lookup(@table, key) do
        [{^key, value, expires_at, _sources}] ->
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
      :ets.insert(@table, {key, value, now_ms() + ttl_ms, sources})
    end

    :ok
  end

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

  @impl true
  def init(_opts) do
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

    {:ok, %{}}
  end

  @doc false
  # Labels arrive as "TasksSync" or "TasksSync:regular" — the suffix is a per-run
  # variant (game mode), and both write the same tables, so the prefix is what
  # ownership is keyed on.
  def handle_sync_stop(@sync_event, _measurements, %{label: label}, _config)
      when is_binary(label) do
    label
    |> String.split(":", parts: 2)
    |> hd()
    |> invalidate_source()
  end

  def handle_sync_stop(_event, _measurements, _metadata, _config), do: :ok
end
