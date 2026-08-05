defmodule EftBuddy.Cache.Warmer do
  @moduledoc """
  Repopulates cache entries as soon as the syncer that owns them finishes, so
  the server pays every cold read and visitors never do.

  ## Why warm at all, when the cache already works

  `EftBuddy.Cache` empties an entry the moment its data changes. That is
  correct, and it means the *next* visitor after every sync pays the full
  round-trip cost to rebuild it — the hideout grid at ~1,000 ms, the ammo table
  at ~1,470 ms. With the flea price feed running every ten minutes, somebody
  eats that cold read six times an hour, forever.

  Nothing about that is necessary. The rebuild does not need a visitor to
  trigger it; it only needs to happen. Doing it here moves the cost onto a
  machine that is idle at 2% CPU and off the person waiting for a page.

  ## Why not at boot

  Boot is the wrong hook. `EftBuddy.Sync.Bootstrap` runs the cold-start sequence
  moments after startup and invalidates, by design, everything a boot-time warm
  had just built. Hooking to sync completion instead means the warm happens
  *exactly* when the cache was emptied — the two events are the same event — so
  the table goes from full to empty to full without ever being observed empty.

  ## Why a separate telemetry handler from the invalidator

  This is the load-bearing detail of the module. `:telemetry` **detaches a
  handler that raises**, permanently, with nothing but a log line. If warming
  ran inside `EftBuddy.Cache`'s invalidation handler, then any warm failure —
  an upstream hiccup, a bad spec, a transient pool timeout — would take
  *invalidation* down with it. The cache would then serve whatever it last held
  until the 20-minute TTL swept it, and the only symptom would be a page
  quietly showing old data.

  So: own handler id, own failure domain, and the handler body does nothing but
  cast a message. Every part that can actually fail happens somewhere a crash is
  survivable.

  ## Shape of the work

  A sync finishing casts its source name here. Names are collected over a short
  window and flushed together, because syncs arrive in bursts (`TasksSync:regular`
  and `TasksSync:pve` land back to back, and Bootstrap runs seven feeds in a
  row). The flush filters specs **by source**, so `HideoutSync` finishing warms
  the hideout entries and nothing else — a Bootstrap run warms each dataset once,
  as its own feed completes, rather than warming everything seven times.

  The batch runs in a separate monitored process with bounded concurrency. Both
  bounds matter: the Ecto pool has ten connections and a sync may still be using
  them, so an unbounded warm would compete with the very feed that triggered it.

  ## Warming on its own is not enough — the entries have to stay

  Warming purely on sync completion leaves a gap this module originally missed.
  Most feeds run every 6 to 24 hours, and the cache's default TTL is twenty
  minutes. So an entry was warmed at sync time, expired twenty minutes later,
  was swept, and nothing rebuilt it until the next sync hours away — the first
  visitor after that paid exactly the cold read warming exists to prevent.
  Measured on the VM: **19 specs registered, 5 live, 25.6% hit rate.** The five
  survivors were the ones reachable from a spec owned by the ten-minute price
  feed, which is the only cadence shorter than the TTL.

  Two mechanisms fix it, and they are deliberately separate because they answer
  different questions:

  * **Per-source TTL** bounds *undetected staleness*. A warm entry expires on
    its owning feed's staleness budget (`EftBuddy.Sync.Freshness`), not on a
    flat twenty minutes — the same number `/health/sync` already reports on. A
    twenty-minute expiry against a 24-hour feed was never a staleness bound, it
    was a guarantee of coldness.
  * **The repair tick** bounds *coldness*, for the cases a TTL cannot cover: a
    warm that failed, a warm killed by a timeout, an entry evicted by the cap, a
    spec added mid-cycle. It is cheap because it PROBES before it runs — see
    `warm_one/1`.

  Raising the TTL alone would have been the wrong fix: it weakens the backstop
  that exists for "the invalidation signal never arrived". Looping a rebuild
  around the old TTL would also have been wrong — it copies every cached value
  out of ETS on every pass, and for the two `:external` specs it is not a
  rebuild-if-needed at all but an unconditional multi-second reload.
  """

  use GenServer

  require Logger

  alias EftBuddy.Cache
  alias EftBuddy.Sync.Freshness

  @sync_event [:eft_buddy, :sync, :stop]
  # Distinct from `{EftBuddy.Cache, :invalidate}`. See the moduledoc.
  @handler_id {__MODULE__, :warm}

  # Collect source names for this long before flushing. Sized to swallow the
  # per-mode pairs that arrive together (`PricesSync:regular` then
  # `PricesSync:pve`) without meaningfully extending the window in which a read
  # would miss — the cache is already empty during it either way.
  #
  # Overridable so the test suite does not spend a real five seconds per
  # assertion waiting for a window whose duration is not what is under test.
  @default_debounce_ms 5_000

  # The pool is ten connections and the sync that triggered this warm may still
  # be finishing its own writes. Warming is by definition not urgent: it is
  # work done ahead of a request that has not arrived.
  @max_concurrency 2

  # A single LIGHT warm that takes longer than this is not worth waiting for;
  # the entry stays cold and the next sync will try again.
  @spec_timeout_ms :timer.seconds(60)

  # Heavy specs get their own, much larger budget and run one at a time. The
  # light 60s would kill a bulk build partway, which is worse than not starting
  # it: the set is half-written, no sentinel is recorded, so every subsequent
  # tick starts the same doomed build again.
  @heavy_timeout_ms :timer.minutes(10)

  # How many repair passes fit inside one TTL. Division rather than subtraction:
  # subtracting gives an expiring entry exactly one chance to be noticed, and a
  # pass deferred behind a running batch would spend it. Three spare passes is
  # the difference between "usually warm" and "warm".
  @repair_divisor 4

  # Bootstrap suspends warming while its seven sequential steps run. This is the
  # backstop for a Bootstrap that dies without resuming. It should never fire —
  # `Bootstrap.run/0` resumes from an `after` block — but a warmer that a
  # crashing caller can switch off permanently is the same silent-failure shape
  # as a detached telemetry handler, and gets the same treatment. A cold start
  # that takes half an hour has failed regardless.
  @max_suspend_ms :timer.minutes(30)

  # The sidebar's own representation (`EftBuddyWeb.OperatorState` holds `:pvp` /
  # `:pve`), NOT the DB strings. `EftBuddy.Items.scope_counts/1` and friends key
  # their cache entry on the raw argument, so warming with `"regular"` would
  # populate a key the UI never reads — a warm that appears to work, costs a
  # query, and leaves the hit rate at zero. Match the call site exactly.
  @ui_modes [:pvp, :pve]

  # ── Public API ─────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The warm registry: which cached reads to rebuild, and which syncers finishing
  should rebuild them.

  Overridable through `:cache_warm_specs` so tests can supply harmless specs
  instead of ones that hit the database — and so warming can be switched off
  entirely (`[]`) on a running node without a deploy.

  ## Spec fields

  * `:label` — display name, and the sentinel key for `:bulk` specs.
  * `:sources` — syncer label prefixes whose completion should rebuild this.
  * `:mfa` — what to call.
  * `:kind` — see below.
  * `:cost` — `:light` runs concurrently, `:heavy` runs strictly alone.
  * `:periodic` — whether the repair tick may run it.
  * `:keys` — for `:entry` specs, the exact cache keys the MFA populates.

  ## Kinds

  * `:entry` — the MFA calls `Cache.fetch/4` and populates the keys in `:keys`.
    The repair tick probes those keys and skips the spec when they are all live,
    which is what makes ticking nearly free.
  * `:bulk` — the MFA writes many entries itself via `Cache.put_many/3` and
    returns `{:ok, count}`. Coverage is tracked with a sentinel entry sharing
    the set's sources and TTL, so an invalidation drops it in the same scan that
    drops the set.
  * `:external` — the MFA writes somewhere other than `EftBuddy.Cache`.

  `:external` specs are never probed and **never ticked**, and that is
  load-bearing rather than an optimisation. Both of them
  (`EftBuddy.Items.Dataset.refresh_catalog/0` and `refresh_prices/0`) are
  unconditional rebuilds: they empty their ETS tables and re-read everything,
  taking 5.5-12.5s and 8.2-13.8s respectively, and they raise a `:building`
  flag that makes `Dataset.ready?/1` false and sends Items and Flea back to the
  SQL path while it is up. On a five-minute tick that is 14-26 seconds out of
  every 300 spent making the app slower. They do not need it: each already
  carries its own staleness bound sized against its own feed.
  """
  def specs do
    :eft_buddy
    |> Application.get_env(:cache_warm_specs, default_specs())
    |> Enum.map(&normalize_spec/1)
  end

  # An override may supply only `label`, `sources` and `mfa` — that is the whole
  # point of the escape hatch, and an operator writing one at a console should
  # not have to know about `:kind`, `:cost`, `:periodic` and `:keys`. Defaults
  # give the conservative reading: an ordinary entry spec with no declared keys,
  # which is never skipped by the probe and never reported cold.
  defp normalize_spec(spec) do
    Map.merge(%{kind: :entry, cost: :light, periodic: true, keys: []}, spec)
  end

  @doc false
  def default_specs do
    [
      spec("hideout.modules", ["HideoutSync"], {EftBuddy.Hideout, :list_modules, []},
        keys: [{EftBuddy.Hideout, :list_modules}]
      ),
      spec("maps.list", ["MapsSync"], {EftBuddy.Maps, :list_maps, [[]]},
        keys: [{EftBuddy.Maps, :list_maps, []}]
      ),
      spec("tasks.traders_with_tasks", ["TasksSync"], {EftBuddy.Tasks, :traders_with_tasks, []},
        keys: [{EftBuddy.Tasks, :traders_with_tasks, nil}]
      ),

      # The app's most expensive read. `list_rounds/0` builds both halves of the
      # split (see `EftBuddy.Ammo`), so warming it covers the ten-minute price
      # tick that drops the availability half without also making a visitor pay
      # to rebuild the ballistics half.
      #
      # Two keys, and they have DIFFERENT owners — ballistics is
      # AmmoSync/ItemsSync, availability adds the price and recipe feeds. The
      # spec lists the union, which is why a price tick rebuilds the cheap half
      # and finds the expensive one already live.
      spec(
        "ammo.rounds",
        ["AmmoSync", "ItemsSync", "PricesSync", "BartersSync", "CraftsSync"],
        {EftBuddy.Ammo, :list_rounds, []},
        keys: [{EftBuddy.Ammo, :ballistics}, {EftBuddy.Ammo, :availability}]
      ),
      spec("armor.plates", ["ArmorSync", "ItemsSync"], {EftBuddy.Armor, :list_plates, []},
        keys: [{EftBuddy.Armor, :list_plates}]
      ),
      spec("events.list", ["EventsSync"], {EftBuddy.Events, :list_events, []},
        keys: [{EftBuddy.Events, :list_events}]
      ),
      spec("chapters.list", ["ChaptersSync"], {EftBuddy.Chapters, :list_chapters, []},
        keys: [{EftBuddy.Chapters, :list_chapters}]
      ),
      spec("wiki.all_quests", ["WikiSync"], {EftBuddy.Wiki, :all_quests, []},
        keys: [{EftBuddy.Wiki, :all_quests}]
      ),
      spec("wiki.quest_slugs", ["WikiSync"], {EftBuddy.Wiki, :quest_slugs, []},
        keys: [{EftBuddy.Wiki, :quest_slugs}]
      ),
      spec("wiki.karma_requirements", ["WikiSync"], {EftBuddy.Wiki, :karma_requirements, []},
        keys: [{EftBuddy.Wiki, :karma_requirements}]
      ),
      spec("chapters.endings", ["ChaptersSync"], {EftBuddy.Chapters, :get_endings, []},
        # `get_endings/0` calls `endings_page/0`, so warming it fills both.
        keys: [{EftBuddy.Chapters, :endings}, {EftBuddy.Chapters, :endings_page}]
      ),
      spec(
        "storyline.item_index",
        ["ChaptersSync", "ItemsSync", "QuestItemsSync"],
        {EftBuddy.Chapters, :item_index, []},
        keys: [{EftBuddy.Chapters, :item_index}]
      ),

      # ── Bulk sets ────────────────────────────────────────
      #
      # These write thousands of id-keyed entries from one query set, so that no
      # visitor is ever the first to open a given panel. Coverage is tracked by
      # a sentinel rather than by enumerating every key on each probe.
      bulk_spec(
        "hideout.level_requirements",
        ["HideoutSync", "ItemsSync"],
        {EftBuddy.Hideout, :warm_level_requirements, []},
        cost: :light
      ),
      bulk_spec(
        "hideout.total_item_costs",
        ["HideoutSync", "ItemsSync"],
        {EftBuddy.Hideout, :warm_total_item_costs, []},
        cost: :light
      ),
      bulk_spec("wiki.quests", ["WikiSync"], {EftBuddy.Wiki, :warm_quests, []}),
      bulk_spec(
        "tasks.details",
        ["TasksSync", "ItemsSync", "HideoutSync", "MapsSync"],
        {EftBuddy.Tasks, :warm_details, []}
      ),

      # The in-memory item catalogue. The catalogue half is rebuilt by every
      # feed that contributes a scope membership set — items themselves, plus
      # the tasks, hideout requirements, barters and crafts the scope tabs are
      # computed from. The price half is on PricesSync alone, which is the
      # entire point of the split: a ten-minute price tick must not trigger a
      # three-second catalogue rebuild.
      #
      # `:external`, so the repair tick leaves them alone — see `specs/0`.
      external_spec(
        "dataset.catalog",
        ["ItemsSync", "TasksSync", "HideoutSync", "BartersSync", "CraftsSync"],
        {EftBuddy.Items.Dataset, :refresh_catalog, []}
      ),
      external_spec(
        "dataset.prices",
        ["PricesSync"],
        {EftBuddy.Items.Dataset, :refresh_prices, []}
      ),

      # The storyline pages' task cross-link index — `preloads: []`, no mode.
      spec(
        "tasks.index",
        ["TasksSync", "HideoutSync"],
        {EftBuddy.Tasks, :list_tasks, [[preloads: []]]},
        keys: [{EftBuddy.Tasks, :list_tasks, [], nil}]
      )
    ] ++
      for mode <- @ui_modes do
        # EXACTLY the Tasks page's call shape. `list_tasks/1` only caches a
        # whitelisted set of option shapes, so a warm that passed anything else
        # would issue the query, discard the result, and cache nothing.
        spec(
          "tasks.list:#{mode}",
          ["TasksSync", "HideoutSync"],
          {EftBuddy.Tasks, :list_tasks, [[preloads: [:trader], game_mode: mode]]},
          keys: [{EftBuddy.Tasks, :list_tasks, [:trader], mode}]
        )
      end ++
      item_detail_specs() ++
      for mode <- @ui_modes do
        spec("tasks.prereq_map:#{mode}", ["TasksSync"], {EftBuddy.Tasks, :prereq_map, [mode]},
          keys: [{EftBuddy.Tasks, :prereq_map, mode}]
        )
      end ++
      for mode <- @ui_modes do
        spec("items.scope_counts:#{mode}", ["ItemsSync"], {EftBuddy.Items, :scope_counts, [mode]},
          keys: [{EftBuddy.Items, :scope_counts, mode}]
        )
      end ++
      for mode <- @ui_modes do
        spec(
          "items.flea_counts:#{mode}",
          # Three owners: the counts come from ItemsSync, flea eligibility from
          # the price columns, and the threshold from the flea settings.
          ["ItemsSync", "PricesSync", "FleaSettingsSync"],
          {EftBuddy.Items, :flea_market_counts_by_category, [mode]},
          keys: [{EftBuddy.Items, :flea_counts_by_category, mode}]
        )
      end
  end

  # The largest sets in the registry: ~5,400 relational panels per mode.
  #
  # Sources deliberately omit PricesSync and must stay identical to
  # `Items.detail_sources/0` — the price-dependent half of a panel is resolved
  # at read time from the dataset's own price layer, so a ten-minute tick does
  # not throw away thousands of entries that do not depend on prices.
  # `cache_source_map_test.exs` pins the two together.
  #
  # Registered ONLY when the builder is switched on, rather than registered
  # unconditionally and left to no-op. A spec that can never populate anything
  # is reported cold forever, and `cold: []` is the single check an operator
  # runs to confirm warming is holding — one permanently-cold row makes that
  # signal unreadable, which is worse than not listing the capability. The
  # dashboard shows the flag's state separately.
  defp item_detail_specs do
    if EftBuddy.Items.details_precompute_enabled?() do
      for mode <- @ui_modes do
        bulk_spec(
          "items.details:#{mode}",
          EftBuddy.Items.detail_sources(),
          {EftBuddy.Items, :warm_item_details, [mode]}
        )
      end
    else
      []
    end
  end

  defp spec(label, sources, mfa, opts) do
    %{
      label: label,
      sources: sources,
      mfa: mfa,
      kind: Keyword.get(opts, :kind, :entry),
      cost: Keyword.get(opts, :cost, :light),
      periodic: Keyword.get(opts, :periodic, true),
      # For `:entry` specs this DUPLICATES knowledge that already lives at the
      # `Cache.fetch/4` call site, which is the one new failure mode this shape
      # introduces. Two things keep it honest: `warm_registry_test.exs` asserts
      # that running each MFA populates exactly these keys and no others, and at
      # runtime a spec that runs and still leaves its keys cold emits
      # `outcome: :no_entry` rather than silently rebuilding on every tick
      # forever.
      keys: Keyword.get(opts, :keys, [])
    }
  end

  # Writes many entries itself and returns `{:ok, count}`.
  #
  # Heavy by default, because a bulk build is a full pass over a dataset — but
  # overridable: the two hideout sets are a couple of queries covering ~100
  # entries, and making those wait behind a serial queue would delay the page
  # that motivated this work for no reason.
  defp bulk_spec(label, sources, mfa, opts \\ []) do
    spec(label, sources, mfa, kind: :bulk, cost: Keyword.get(opts, :cost, :heavy))
  end

  # Writes somewhere other than `EftBuddy.Cache`, so there is nothing to probe
  # and nothing the repair tick could usefully do. See `specs/0` for why this
  # must stay `periodic: false`.
  defp external_spec(label, sources, mfa),
    do: spec(label, sources, mfa, kind: :external, cost: :heavy, periodic: false)

  @doc """
  Warm everything, now, regardless of which syncer last finished.

  For an operator at a remote console after clearing the cache by hand, and for
  the dashboard's warm button. Asynchronous — it returns immediately.

  `warm_all/0` covers the light specs only, which finish in seconds.
  `warm_all(:all)` includes the heavy bulk builds, which take minutes — an
  operator should choose that deliberately rather than discover it by clicking
  a button labelled "Warm now".
  """
  def warm_all, do: warm_all(:light)

  def warm_all(scope) when scope in [:light, :all] do
    GenServer.cast(__MODULE__, {:warm_all, scope})
  end

  @doc """
  Stop flushing. Sources still ACCUMULATE — nothing is lost — but no batch runs
  until `resume/0`.

  For `EftBuddy.Sync.Bootstrap`, whose seven sequential steps are minutes apart
  and so are not collapsed by the debounce. Without this a cold start rebuilds
  the item catalogue four times, three of them against data the next step is
  about to change.
  """
  def suspend, do: GenServer.cast(__MODULE__, :suspend)

  @doc "Resume, and flush once for the union of everything that accumulated."
  def resume, do: GenServer.cast(__MODULE__, :resume)

  @doc """
  Per-spec liveness: what the registry expects to be warm, and what actually is.

  This is the number that makes the failure mode visible. When 5 of 19 specs
  were live in production, every other signal looked fine — the entry count was
  non-zero, memory was non-zero, and the hit rate read as "low, but the cache is
  young". None of them can express "the entries that are supposed to be warm are
  not".
  """
  def coverage, do: GenServer.call(__MODULE__, :coverage)

  @doc false
  # Invoked by `:telemetry_poller` (see `EftBuddyWeb.Telemetry`).
  #
  # Polled rather than event-driven, for the same reason the cache's own state
  # is: the interesting condition here is one where nothing happens. A registry
  # that has gone cold emits no event — it just stops being warm.
  def emit_telemetry do
    summary = coverage_summary()

    :telemetry.execute(
      [:eft_buddy, :cache, :warm, :state],
      %{specs_live: summary.live, specs_total: summary.total},
      %{}
    )
  end

  @doc """
  Summary of `coverage/0`: how many specs are live, and which are not.

  Computed straight from the registry and ETS rather than through the
  GenServer. `coverage/0` has to ask the server because it reports each spec's
  last warm outcome, which lives in server state — but liveness does not, and
  routing this through a `call` made it fail during boot: `EftBuddyWeb.Telemetry`
  is the first child in the supervision tree and this warmer is the fourth, so
  the first poll called a process that did not exist yet. Observed in
  production as `Error when calling MFA defined by measurement`.
  """
  def coverage_summary do
    rows = Enum.map(specs(), &liveness/1)

    %{
      total: length(rows),
      live: Enum.count(rows, &(&1.state == :live)),
      cold: rows |> Enum.reject(&(&1.state in [:live, :unprobed])) |> Enum.map(& &1.label)
    }
  end

  @doc """
  Whether a warm is queued, scheduled, or currently running.

  Exists for tests. Warming is asynchronous and debounced, so a batch triggered
  by one test can land in the middle of the next one and write an entry into a
  table that test had just cleared — a cross-test leak that presents as a
  baffling off-by-one and depends on the seed. Polling this to idle before
  clearing removes the race rather than papering over it with a longer sleep.
  """
  def busy?, do: GenServer.call(__MODULE__, :busy?)

  @doc false
  # Public so `EftBuddyWeb.Telemetry` and tests can reach it, and so the handler
  # is a named function rather than a closure captured at attach time.
  #
  # Does nothing but cast. Everything that can fail is on the other side of that
  # message, in a process whose death is survivable — see the moduledoc.
  def handle_sync_stop(@sync_event, _measurements, %{label: label}, _config)
      when is_binary(label) do
    source = label |> String.split(":", parts: 2) |> hd()
    GenServer.cast(__MODULE__, {:warm_sources, [source]})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def handle_sync_stop(_event, _measurements, _metadata, _config), do: :ok

  # ── Server ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :telemetry.attach(@handler_id, @sync_event, &__MODULE__.handle_sync_stop/4, nil)

    {:ok,
     %{
       pending: MapSet.new(),
       timer: nil,
       batch: nil,
       repair_timer: schedule_repair(),
       repair_due?: false,
       suspended?: false,
       suspend_timer: nil,
       results: %{}
     }}
  end

  @impl true
  def handle_call(:busy?, _from, state) do
    # The batch writes to ETS before it exits, and its `:DOWN` is queued ahead of
    # this call, so a `false` here means every write has already landed.
    busy? = state.batch != nil or state.timer != nil or MapSet.size(state.pending) > 0

    {:reply, busy?, state}
  end

  def handle_call(:coverage, _from, state) do
    {:reply, Enum.map(specs(), &coverage_row(&1, state.results)), state}
  end

  @impl true
  def handle_cast({:warm_sources, sources}, state) do
    # Nothing to warm into. Dev and test run with the cache off, and a warm
    # would then be a pure cost: real queries whose results are discarded.
    if Cache.enabled?() do
      {:noreply, state |> add_pending(sources) |> ensure_timer()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:warm_all, scope}, state) do
    if Cache.enabled?() do
      sources =
        specs()
        |> Enum.filter(&(scope == :all or &1.cost == :light))
        |> Enum.flat_map(& &1.sources)
        |> Enum.uniq()

      {:noreply, state |> add_pending(sources) |> ensure_timer()}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:suspend, state) do
    cancel(state.suspend_timer)

    {:noreply,
     %{
       state
       | suspended?: true,
         suspend_timer: Process.send_after(self(), :suspend_expired, @max_suspend_ms)
     }}
  end

  def handle_cast(:resume, state) do
    cancel(state.suspend_timer)
    state = %{state | suspended?: false, suspend_timer: nil}

    # Flush immediately rather than waiting out another debounce. Bootstrap has
    # just finished; the endpoint is already serving and the cache is empty.
    {:noreply, if(MapSet.size(state.pending) > 0, do: ensure_timer(state), else: state)}
  end

  @impl true
  def handle_info(:repair, state) do
    # Set a flag and let the ordinary debounce path do the flush, so a repair
    # landing next to a sync-driven warm coalesces into one batch instead of
    # queueing behind it.
    {:noreply, %{state | repair_due?: true, repair_timer: schedule_repair()} |> ensure_timer()}
  end

  def handle_info(:suspend_expired, state) do
    Logger.error("""
    [Cache.Warmer] still suspended #{div(@max_suspend_ms, 60_000)} minutes after \
    EftBuddy.Sync.Bootstrap asked for it. Bootstrap should resume from an `after` \
    block, so this means it died without doing so. Resuming anyway — a cold start \
    that takes this long has failed regardless, and a permanently suspended warmer \
    is the silent failure this guard exists to prevent.\
    """)

    {:noreply, %{state | suspended?: false, suspend_timer: nil} |> ensure_timer()}
  end

  def handle_info(:flush, %{batch: batch} = state) when not is_nil(batch) do
    # A batch is still running. Leave `pending` and `repair_due?` intact and come
    # back to them — two concurrent batches would double the pool pressure the
    # concurrency bound exists to prevent.
    {:noreply, %{state | timer: schedule()}}
  end

  def handle_info(:flush, %{suspended?: true} = state) do
    # Keep accumulating; `resume/0` will flush the union.
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:flush, state) do
    sources = MapSet.to_list(state.pending)

    due =
      (matching_specs(sources) ++ if(state.repair_due?, do: periodic_specs(), else: []))
      |> Enum.uniq_by(& &1.label)

    case due do
      [] ->
        {:noreply, %{state | pending: MapSet.new(), timer: nil, repair_due?: false}}

      due ->
        # `spawn_monitor`, not a link: a batch that dies must not take this
        # GenServer — and therefore the telemetry handler — with it.
        server = self()
        {pid, ref} = spawn_monitor(fn -> run_batch(due, server) end)

        {:noreply,
         %{state | pending: MapSet.new(), timer: nil, repair_due?: false, batch: {pid, ref}}}
    end
  end

  def handle_info({:warm_result, label, result}, state) do
    {:noreply, %{state | results: Map.put(state.results, label, result)}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{batch: {pid, ref}} = state) do
    if reason != :normal do
      Logger.warning("[Cache.Warmer] warm batch exited: #{inspect(reason)}")
    end

    state = %{state | batch: nil}

    # Sources that arrived while the batch was running still need a flush.
    if MapSet.size(state.pending) > 0 or state.repair_due? do
      {:noreply, ensure_timer(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internals ──────────────────────────────────────────

  defp add_pending(state, sources) do
    %{state | pending: Enum.into(sources, state.pending)}
  end

  defp ensure_timer(%{suspended?: true} = state), do: state
  defp ensure_timer(%{timer: nil} = state), do: %{state | timer: schedule()}
  defp ensure_timer(state), do: state

  defp schedule, do: Process.send_after(self(), :flush, debounce_ms())

  defp schedule_repair, do: Process.send_after(self(), :repair, repair_interval_ms())

  defp cancel(nil), do: :ok
  defp cancel(ref), do: Process.cancel_timer(ref)

  @doc false
  # Public so tests can derive their own settle time from the same value rather
  # than hard-coding a sleep that silently stops covering anything if the window
  # is ever changed.
  def debounce_ms,
    do: Application.get_env(:eft_buddy, :cache_warm_debounce_ms, @default_debounce_ms)

  @doc """
  How often the repair pass runs, derived from the cache's own TTL.

  Derived rather than configured so the two cannot drift: a warmer ticking on
  one number while the cache expires on another is exactly what left most of the
  registry cold.
  """
  def repair_interval_ms, do: max(div(Cache.default_ttl_ms(), @repair_divisor), 1_000)

  defp matching_specs(sources) do
    Enum.filter(specs(), fn spec -> Enum.any?(spec.sources, &(&1 in sources)) end)
  end

  defp periodic_specs, do: Enum.filter(specs(), & &1.periodic)

  # Light specs first and concurrently: they are what a visitor is most likely
  # to need next, and they finish in seconds. Heavy specs then run strictly one
  # at a time — a bulk build is minutes of sustained query load, and two of them
  # against ten pool connections is the shape that turns warming into an outage.
  defp run_batch(specs, server) do
    {heavy, light} = Enum.split_with(specs, &(&1.cost == :heavy))

    light
    |> Task.async_stream(&warm_one(&1, server),
      max_concurrency: @max_concurrency,
      timeout: @spec_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()

    Enum.each(heavy, &run_heavy(&1, server))
  end

  # `Enum.each` has no timeout of its own, and the light phase's 60s budget
  # would kill a bulk build partway — leaving a half-written set, no sentinel,
  # and an identical doomed rebuild on every subsequent tick.
  defp run_heavy(spec, server) do
    task = Task.async(fn -> warm_one(spec, server) end)

    case Task.yield(task, @heavy_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      _ ->
        Logger.warning("[Cache.Warmer] #{spec.label} timed out after #{@heavy_timeout_ms}ms")
        emit_warm(server, spec.label, :timeout, 0, 0)
        :timeout
    end
  end

  defp warm_one(spec, server) do
    Cache.mark_warm_process()
    Cache.put_ttl_override(warm_ttl_ms(spec.sources))

    if skip?(spec) do
      emit_warm(server, spec.label, :skipped, 0, 0)
      :skipped
    else
      do_warm(spec, server)
    end
  end

  # The probe that makes a periodic tick affordable. An `:entry` spec whose keys
  # are all live costs a handful of integer reads — no query, no ETS copy, and
  # no effect on the hit-rate metric.
  #
  # It also preserves `inserted_at` on a healthy entry, which matters more than
  # it looks: the dashboard's Age column means "how long since this data was
  # rebuilt", and a tick that re-ran unconditionally would reset it everywhere
  # and destroy that diagnosis while appearing to fix the cache.
  defp skip?(%{kind: :entry, keys: [_ | _] = keys}), do: Enum.all?(keys, &Cache.live?/1)
  defp skip?(%{kind: :bulk, label: label}), do: Cache.live?(sentinel_key(label))
  defp skip?(_spec), do: false

  defp do_warm(%{kind: kind, label: label, mfa: {mod, fun, args}} = spec, server) do
    started = System.monotonic_time(:millisecond)
    result = apply(mod, fun, args)
    duration = System.monotonic_time(:millisecond) - started

    {outcome, entries} = record_outcome(kind, spec, result)
    emit_warm(server, label, outcome, duration, entries)

    :ok
  rescue
    e ->
      # A warm failure is not an incident. The entry simply stays cold, the next
      # reader rebuilds it the old way, and the next sync tries again — so this
      # is a warning, not an error, and it must never propagate.
      Logger.warning("[Cache.Warmer] #{label} failed to warm: #{Exception.message(e)}")
      emit_warm(server, label, :error, 0, 0)

      :error
  end

  # A `:bulk` builder returns `{:ok, count}` and writes its own entries; the
  # sentinel records that the set is complete. It shares the set's sources and
  # TTL deliberately, so `invalidate_source/1` drops it in the same scan that
  # drops the set — a sentinel outliving its entries would suppress the rebuild
  # that is supposed to follow an invalidation.
  defp record_outcome(:bulk, %{label: label, sources: sources}, {:ok, count}) do
    Cache.put(sentinel_key(label), %{count: count}, sources)
    {:ok, count}
  end

  defp record_outcome(:entry, %{keys: [_ | _] = keys}, _result) do
    # Re-probe. A spec that ran and STILL leaves its keys cold means the keys it
    # declares are not the keys its MFA writes — a warm that costs a query,
    # populates something nothing reads, and would otherwise re-run on every
    # single tick forever, silently.
    if Enum.all?(keys, &Cache.live?/1), do: {:ok, length(keys)}, else: {:no_entry, 0}
  end

  defp record_outcome(_kind, _spec, _result), do: {:ok, 0}

  defp emit_warm(server, label, outcome, duration_ms, entries) do
    send(
      server,
      {:warm_result, label,
       %{outcome: outcome, at: DateTime.utc_now(), duration_ms: duration_ms, entries: entries}}
    )

    :telemetry.execute(
      [:eft_buddy, :cache, :warm],
      %{duration_ms: duration_ms, entries: entries},
      %{label: label, outcome: outcome}
    )
  end

  @doc false
  # The sentinel a `:bulk` spec writes alongside its set. Public only so tests
  # can assert on it; bulk builders never see it.
  def sentinel_key(label), do: {__MODULE__, :bulk, label}

  @doc """
  How long a warm-written entry should live, given the syncers that own it.

  The MINIMUM budget across sources, because the strictest owner is the first
  ingredient that can go wrong: `ammo.rounds` is fed by five feeds, one of which
  is the two-hourly price budget, so the entry expires on that schedule.

  Floored at the cache default so this can only ever extend an entry's life. The
  numbers come from `EftBuddy.Sync.Freshness`, which is already the single
  source of truth for feed cadence and is drift-tested against the real
  intervals — so a feed whose interval changes cannot leave a stale TTL behind.
  """
  def warm_ttl_ms(sources) do
    sources
    |> Enum.map(&Freshness.budget_seconds/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> Cache.default_ttl_ms()
      budgets -> budgets |> Enum.min() |> :timer.seconds()
    end
    |> max(Cache.default_ttl_ms())
  end

  # The part of a coverage row that needs only the registry and ETS.
  defp liveness(spec) do
    {expected, live} =
      case spec do
        %{kind: :entry, keys: [_ | _] = keys} -> {length(keys), Cache.live_count(keys)}
        %{kind: :bulk, label: label} -> {1, Cache.live_count([sentinel_key(label)])}
        _ -> {0, 0}
      end

    %{
      label: spec.label,
      kind: spec.kind,
      cost: spec.cost,
      periodic: spec.periodic,
      sources: spec.sources,
      expected: expected,
      live: live,
      state: coverage_state(expected, live)
    }
  end

  defp coverage_row(spec, results) do
    last = Map.get(results, spec.label, %{})

    spec
    |> liveness()
    |> Map.merge(%{
      last_outcome: Map.get(last, :outcome),
      last_warm_at: Map.get(last, :at),
      last_warm_ms: Map.get(last, :duration_ms),
      last_entries: Map.get(last, :entries)
    })
  end

  # `:external` specs write outside `EftBuddy.Cache`, so there is nothing to
  # probe — reporting them as cold would be a permanent false alarm.
  defp coverage_state(0, _live), do: :unprobed
  defp coverage_state(expected, expected), do: :live
  defp coverage_state(_expected, 0), do: :cold
  defp coverage_state(_expected, _live), do: :partial
end
