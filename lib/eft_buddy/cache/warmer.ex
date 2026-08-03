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
  """

  use GenServer

  require Logger

  alias EftBuddy.Cache

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

  # A single warm that takes longer than this is not worth waiting for; the
  # entry stays cold and the next sync will try again.
  @spec_timeout_ms :timer.seconds(60)

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
  """
  def specs, do: Application.get_env(:eft_buddy, :cache_warm_specs, default_specs())

  @doc false
  def default_specs do
    [
      spec("hideout.modules", ["HideoutSync"], {EftBuddy.Hideout, :list_modules, []}),
      spec("maps.list", ["MapsSync"], {EftBuddy.Maps, :list_maps, [[]]}),
      spec("tasks.traders_with_tasks", ["TasksSync"], {EftBuddy.Tasks, :traders_with_tasks, []}),

      # The app's most expensive read. `list_rounds/0` builds both halves of the
      # split (see `EftBuddy.Ammo`), so warming it covers the ten-minute price
      # tick that drops the availability half without also making a visitor pay
      # to rebuild the ballistics half.
      spec(
        "ammo.rounds",
        ["AmmoSync", "ItemsSync", "PricesSync", "BartersSync", "CraftsSync"],
        {EftBuddy.Ammo, :list_rounds, []}
      ),
      spec("armor.plates", ["ArmorSync", "ItemsSync"], {EftBuddy.Armor, :list_plates, []}),
      spec("events.list", ["EventsSync"], {EftBuddy.Events, :list_events, []}),
      spec("chapters.list", ["ChaptersSync"], {EftBuddy.Chapters, :list_chapters, []}),
      spec("wiki.all_quests", ["WikiSync"], {EftBuddy.Wiki, :all_quests, []}),

      # The in-memory item catalogue. The catalogue half is rebuilt by every
      # feed that contributes a scope membership set — items themselves, plus
      # the tasks, hideout requirements, barters and crafts the scope tabs are
      # computed from. The price half is on PricesSync alone, which is the
      # entire point of the split: a ten-minute price tick must not trigger a
      # three-second catalogue rebuild.
      spec(
        "dataset.catalog",
        ["ItemsSync", "TasksSync", "HideoutSync", "BartersSync", "CraftsSync"],
        {EftBuddy.Items.Dataset, :refresh_catalog, []}
      ),
      spec("dataset.prices", ["PricesSync"], {EftBuddy.Items.Dataset, :refresh_prices, []}),

      # The storyline pages' task cross-link index — `preloads: []`, no mode.
      spec(
        "tasks.index",
        ["TasksSync", "HideoutSync"],
        {EftBuddy.Tasks, :list_tasks, [[preloads: []]]}
      )
    ] ++
      for mode <- @ui_modes do
        # EXACTLY the Tasks page's call shape. `list_tasks/1` only caches a
        # whitelisted set of option shapes, so a warm that passed anything else
        # would issue the query, discard the result, and cache nothing.
        spec(
          "tasks.list:#{mode}",
          ["TasksSync", "HideoutSync"],
          {EftBuddy.Tasks, :list_tasks, [[preloads: [:trader], game_mode: mode]]}
        )
      end ++
      for mode <- @ui_modes do
        spec("tasks.prereq_map:#{mode}", ["TasksSync"], {EftBuddy.Tasks, :prereq_map, [mode]})
      end ++
      for mode <- @ui_modes do
        spec("items.scope_counts:#{mode}", ["ItemsSync"], {EftBuddy.Items, :scope_counts, [mode]})
      end ++
      for mode <- @ui_modes do
        spec(
          "items.flea_counts:#{mode}",
          # Three owners: the counts come from ItemsSync, flea eligibility from
          # the price columns, and the threshold from the flea settings.
          ["ItemsSync", "PricesSync", "FleaSettingsSync"],
          {EftBuddy.Items, :flea_market_counts_by_category, [mode]}
        )
      end
  end

  defp spec(label, sources, mfa), do: %{label: label, sources: sources, mfa: mfa}

  @doc """
  Warm everything, now, regardless of which syncer last finished.

  For an operator at a remote console after clearing the cache by hand, and for
  the dashboard's warm button. Asynchronous — it returns immediately.
  """
  def warm_all do
    GenServer.cast(
      __MODULE__,
      {:warm_sources, specs() |> Enum.flat_map(& &1.sources) |> Enum.uniq()}
    )
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

    {:ok, %{pending: MapSet.new(), timer: nil, batch: nil}}
  end

  @impl true
  def handle_call(:busy?, _from, state) do
    # The batch writes to ETS before it exits, and its `:DOWN` is queued ahead of
    # this call, so a `false` here means every write has already landed.
    busy? = state.batch != nil or state.timer != nil or MapSet.size(state.pending) > 0

    {:reply, busy?, state}
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

  @impl true
  def handle_info(:flush, %{batch: batch} = state) when not is_nil(batch) do
    # A batch is still running. Leave `pending` intact and come back to it — two
    # concurrent batches would double the pool pressure the concurrency bound
    # exists to prevent.
    {:noreply, %{state | timer: schedule()}}
  end

  def handle_info(:flush, state) do
    sources = MapSet.to_list(state.pending)

    case matching_specs(sources) do
      [] ->
        {:noreply, %{state | pending: MapSet.new(), timer: nil}}

      specs ->
        # `spawn_monitor`, not a link: a batch that dies must not take this
        # GenServer — and therefore the telemetry handler — with it.
        {pid, ref} = spawn_monitor(fn -> run_batch(specs) end)

        {:noreply, %{state | pending: MapSet.new(), timer: nil, batch: {pid, ref}}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{batch: {pid, ref}} = state) do
    if reason != :normal do
      Logger.warning("[Cache.Warmer] warm batch exited: #{inspect(reason)}")
    end

    state = %{state | batch: nil}

    # Sources that arrived while the batch was running still need a flush.
    if MapSet.size(state.pending) > 0 do
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

  defp ensure_timer(%{timer: nil} = state), do: %{state | timer: schedule()}
  defp ensure_timer(state), do: state

  defp schedule, do: Process.send_after(self(), :flush, debounce_ms())

  @doc false
  # Public so tests can derive their own settle time from the same value rather
  # than hard-coding a sleep that silently stops covering anything if the window
  # is ever changed.
  def debounce_ms,
    do: Application.get_env(:eft_buddy, :cache_warm_debounce_ms, @default_debounce_ms)

  defp matching_specs(sources) do
    Enum.filter(specs(), fn spec -> Enum.any?(spec.sources, &(&1 in sources)) end)
  end

  defp run_batch(specs) do
    specs
    |> Task.async_stream(&warm_one/1,
      max_concurrency: @max_concurrency,
      timeout: @spec_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Stream.run()
  end

  defp warm_one(%{label: label, mfa: {mod, fun, args}}) do
    started = System.monotonic_time(:millisecond)
    apply(mod, fun, args)
    duration = System.monotonic_time(:millisecond) - started

    :telemetry.execute(
      [:eft_buddy, :cache, :warm],
      %{duration_ms: duration},
      %{label: label, outcome: :ok}
    )

    :ok
  rescue
    e ->
      # A warm failure is not an incident. The entry simply stays cold, the next
      # reader rebuilds it the old way, and the next sync tries again — so this
      # is a warning, not an error, and it must never propagate.
      Logger.warning("[Cache.Warmer] #{label} failed to warm: #{Exception.message(e)}")

      :telemetry.execute(
        [:eft_buddy, :cache, :warm],
        %{duration_ms: 0},
        %{label: label, outcome: :error}
      )

      :error
  end
end
