defmodule EftBuddy.Items.Sync do
  @moduledoc """
  Periodically syncs items, categories, vendors and price rows from the
  tarkov.dev JSON API (via `EftBuddy.TarkovApi`) into the local database.

  Runs on two cadences:

    * **Full pipeline** (`run/0`, every `@default_full_interval`) upserts
      the whole snapshot — items, quest items, barters, crafts — and
      prunes anything the API dropped. This is structural data that only
      changes on game patches, so it runs a few times a day.

    * **Price refresh** (`run_prices/0`, every `@default_price_interval`)
      updates only the volatile flea-market price columns on items whose
      prices actually changed (change detection). It performs no
      structural writes and no stale-cleanup, so it's safe to run often
      without the catalog-wide write churn the full pipeline incurs.

  Both paths are idempotent and guarded by a cluster-wide lock so they
  never overlap or race a Bootstrap-driven cold-start run. Items / prices
  that disappear from the API are removed by the full pipeline (subject to
  the `cleanup_safe?/3` partial-snapshot guard).
  """

  use GenServer

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Repo

  alias EftBuddy.Items.{
    Barter,
    BarterRequiredItem,
    BarterRewardItem,
    BuyFor,
    Category,
    Craft,
    CraftRequiredItem,
    CraftRewardItem,
    Item,
    ItemPrice,
    SellFor,
    Vendor
  }

  alias EftBuddy.Hideout.{Station, StationLevel, Trader}
  alias EftBuddy.Tasks.Task, as: TaskRow

  alias EftBuddy.Sync.Reporter

  # All durations are in milliseconds and MUST be integers — `Process.send_after/3`
  # rejects floats with an ArgumentError.
  #
  # Two cadences (see init/1 and handle_info/2):
  #
  #   * `@default_full_interval` — the heavy, structural pipeline (items,
  #     quest items, barters, crafts, stale-cleanup). This data only
  #     changes on game patches/wipes, so re-writing the whole catalog
  #     (≈100k item rows + every price/barter/craft child row) every few
  #     minutes was pure churn — bloating the tables and hammering
  #     autovacuum. Run it a few times a day instead.
  #
  #   * `@default_price_interval` — a lightweight refresh that updates
  #     ONLY the volatile flea-market price columns on items whose prices
  #     actually changed (change detection). No structural writes, no
  #     price-row/barter/craft churn, no cleanup.
  @default_full_interval 6 * 60 * 60 * 1_000

  # 10 minutes, against an upstream that refreshes roughly every 15.
  #
  # Polling faster than the source updates does NOT make the data fresher than
  # the source — nothing can. What it removes is the phase-misalignment penalty:
  # with both sides on 15-minute cycles, a refresh landing just after our tick
  # waits nearly a full interval to be picked up, so worst-case age is our
  # interval on top of theirs. At 10 minutes that added lag is bounded by 10
  # rather than 15, and the average roughly halves.
  #
  # The cost is 50% more calls to an endpoint we do not own, for a refresh that
  # writes only the volatile price columns and only for rows whose prices
  # actually changed. If that ever needs backing off, set `:price_interval` in
  # config rather than editing this — `normalize_ms/2` below already reads it.
  @default_price_interval 10 * 60 * 1_000

  # Cluster-wide lock used by every public `run/*` entry point so a
  # Bootstrap-driven cold-start run can't race with a periodic
  # GenServer tick (or a manual call from another node). Tasks.Sync
  # uses the same `:global.set_lock/3` pattern; we mirror it here so
  # all three syncers behave the same way.
  @lock_id {__MODULE__, :running}

  # ── Client API ─────────────────────────────────────────

  # Cluster-wide singleton: only one node in the cluster runs the
  # GenServer at a time. The losing nodes simply :ignore start_link,
  # so their supervisor leaves the slot empty. If the winning node
  # dies, the next supervisor restart on any node will register
  # globally and take over.
  #
  # Note: cold-start data population is owned by
  # `EftBuddy.Sync.Bootstrap`. This GenServer is responsible only
  # for steady-state periodic refresh after the cold start has run.
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Logger.info(
          "[#{prefix()}] Another node already runs the sync; staying idle on this node."
        )

        :ignore
    end
  end

  @doc """
  Trigger a periodic-style sync immediately. Async (cast).

  Equivalent to letting the next interval tick fire right now;
  intended for tests / manual nudges. For a synchronous call that
  returns the result, use `run/0`.
  """
  def sync_now, do: GenServer.cast({:global, __MODULE__}, :sync_now)

  @doc """
  Run the full items pipeline synchronously: items + categories +
  vendors + prices, followed by barters and crafts. Returns

      {:ok, %{items: count, barters: result, crafts: result}}

  on success or `{:error, reason}` on a failed items step. The
  barters / crafts sub-steps each return their own
  `{:ok, count} | {:skip, reason} | {:error, reason}` so a partial
  outcome is observable rather than collapsed into one verdict.

  Returns `{:error, :already_running}` if any other `run*/0` from
  this module is in progress on the cluster.

  Used by `EftBuddy.Sync.Bootstrap` for the cold-start sequence
  and by the periodic GenServer tick for steady-state refresh.
  """
  def run, do: with_global_lock(&do_run_full/0)

  @doc """
  Run only the items half of the pipeline (items + categories +
  vendors + prices), followed by quest items. Returns
  `{:ok, count}` (the regular-items count) or `{:error, reason}`.

  Bootstrap calls this *before* the hideout sync so the items
  table is populated when hideout's item-requirement resolver
  looks for FK targets. Chaining quest items here means a
  Tasks.Sync run (Bootstrap step 4) sees them in the items map
  when it resolves `obj['questItem']` to a local UUID — without
  that, every objective's quest-item reference would silently
  drop and the Tasks page would render no quest-item tile.

  Quest-item failures are logged via `sync_quest_items_safe/0`
  and do NOT propagate up: a transient API issue on quest items
  shouldn't roll back the (much larger) regular-items pipeline
  that just succeeded.
  """
  def run_items, do: with_global_lock(&do_run_items/0)

  @doc """
  Run only the barters + crafts half of the pipeline. Assumes
  items are already populated (by `run_items/0`) and that hideout
  traders + station_levels are populated (by
  `EftBuddy.Hideout.Sync.run/0`); without those, every row gets
  filtered out by `sanitize_barters/3` / `sanitize_crafts/3` and
  the inserts skip with a logged reason.

  Returns `{:ok, %{barters: result, crafts: result}}` where each
  result is `{:ok, count} | {:skip, reason} | {:error, reason}`.
  """
  def run_barters_and_crafts, do: with_global_lock(&do_run_barters_and_crafts/0)

  @doc """
  Lightweight price refresh: updates the volatile flea-market price
  columns (`avg/low/high_24h_price`, `last_low_price`) on items whose
  prices actually changed since the last run, and appends a point to
  each item's `historical_prices`
  series (the JSON API carries no time series of its own, so the price
  graphs are built from these accumulated snapshots).

  Unlike `run/0` this does NOT touch the structural columns, the entity
  `items` rows beyond the legacy price mirror, barters, crafts, quest
  items, or run stale-cleanup — so it can run frequently without the
  catalog-wide write churn the full pipeline incurs. Returns
  `{:ok, %{checked: n, updated: m}}` or `{:error, reason}`. Returns
  `{:error, :already_running}` if another `run*/0` from this module
  holds the cluster lock.
  """
  def run_prices, do: with_global_lock(&do_run_prices/0)

  @doc false
  # The default tick intervals, in milliseconds. Public so `EftBuddy.Sync.Freshness`
  # can assert its staleness budgets are comfortably larger than the cadences they
  # cover — otherwise the two numbers drift and the health probe either false-alarms
  # or stops detecting a stopped feed, both silently.
  def full_interval_ms, do: @default_full_interval
  @doc false
  def price_interval_ms, do: @default_price_interval

  # ── The `EftBuddy.Sync.Registry` contract ──────────────
  #
  # This module has not adopted `EftBuddy.Sync.Scheduler` yet — it is still one
  # GenServer running several feeds' work on two timers, and it splits into
  # separate modules next. Until then it implements the registry's surface by
  # hand, because the registry is what casts `:bootstrap_complete` and a cast
  # with no matching clause takes the GenServer down.

  @doc false
  # This module's slot, matching the other feeds' staggers.
  @stagger 10 * 60 * 1_000

  @doc false
  def label, do: "ItemsSync"

  @doc false
  # The structural cadence, which is what `ItemsSync`'s staleness budget covers.
  # The price tick has its own budget under its own label.
  def interval_ms, do: @default_full_interval

  @doc false
  def stagger_ms, do: @stagger

  @doc false
  # Bootstrap runs this feed itself during the cold start, so the first recurring
  # run is a full interval away.
  def bootstrap_mode, do: :ran

  # ── Server callbacks ───────────────────────────────────

  @impl true
  def init(opts) do
    full_interval =
      opts
      |> Keyword.get(:full_interval, @default_full_interval)
      |> normalize_ms(@default_full_interval)

    price_interval =
      opts
      |> Keyword.get(:price_interval, @default_price_interval)
      |> normalize_ms(@default_price_interval)

    # First ticks happen after a full interval — Bootstrap handles the
    # cold start, so we don't need a short initial delay here. Jitter is
    # applied so a multi-node deploy with rolling restarts doesn't see
    # every node fire at the same instant.
    #
    # This is a FALLBACK, not the normal path: `:bootstrap_complete` re-arms the
    # full tick from the end of the cold start. Until this module joined
    # `EftBuddy.Sync.Registry.notifiable/0` it never received that cast, so its
    # cadence drifted from boot rather than anchoring to the sequence — silently,
    # because a feed that runs on the wrong schedule still runs.
    full_timer = Process.send_after(self(), :full_sync, full_interval + jitter(full_interval))
    Process.send_after(self(), :price_sync, price_interval + jitter(price_interval))

    {:ok, %{full_interval: full_interval, price_interval: price_interval, full_timer: full_timer}}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    safe_run("Periodic full", &run/0)
    {:noreply, state}
  end

  # Bootstrap finished the cold-start sequence, which already ran this feed's
  # work. Re-arm the FULL tick a whole interval plus this module's stagger from
  # now, cancelling the boot-time timer — arming at zero would immediately
  # re-sync a snapshot written moments ago.
  #
  # The price tick is deliberately left alone: it is ten minutes, so anchoring it
  # would buy nothing and it has its own freshness budget.
  def handle_cast(:bootstrap_complete, %{full_interval: interval} = state) do
    if state[:full_timer], do: Process.cancel_timer(state.full_timer)

    delay = interval + @stagger
    timer = Process.send_after(self(), :full_sync, delay + jitter(delay))

    {:noreply, %{state | full_timer: timer}}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info(:full_sync, %{full_interval: interval} = state) do
    safe_run("Periodic full", &run/0)
    timer = Process.send_after(self(), :full_sync, interval + jitter(interval))
    {:noreply, %{state | full_timer: timer}}
  end

  @impl true
  def handle_info(:price_sync, %{price_interval: interval} = state) do
    safe_run("Periodic price", &run_prices/0)
    Process.send_after(self(), :price_sync, interval + jitter(interval))
    {:noreply, state}
  end

  # GenServer tick wrapper: runs the given `fun`, logs a single summary
  # line per outcome, and swallows crashes so a one-off exception doesn't
  # take the supervisor down.
  defp safe_run(label, fun) do
    case fun.() do
      {:ok, summary} ->
        Logger.info("[#{prefix()}] #{label} run done: #{inspect(summary)}")

      {:error, :already_running} ->
        Logger.info("[#{prefix()}] #{label} run skipped: another sync is already running")

      {:error, reason} ->
        Logger.error("[#{prefix()}] #{label} run error: #{Reporter.describe_error(reason)}")
    end
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] Crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )
  catch
    kind, value ->
      Logger.error("[#{prefix()}] Caught #{kind}: #{inspect(value)}")
  end

  # ── Synchronous `run*` plumbing ────────────────────────

  # Runs items first (rolls back on error), then attempts barters
  # and crafts independently. Each sub-step is wrapped so its own
  # crashes / errors are logged but don't poison the others.
  defp do_run_full do
    case do_run_items() do
      {:ok, item_count} ->
        {:ok, %{barters: barters, crafts: crafts}} = do_run_barters_and_crafts()
        {:ok, %{items: item_count, barters: barters, crafts: crafts}}

      {:error, reason} ->
        Logger.error("[#{prefix()}] Items error: #{Reporter.describe_error(reason)}")
        {:error, reason}
    end
  end

  defp do_run_barters_and_crafts do
    # Barters genuinely differ between modes (~6% of recipes) and the
    # API gives them mode-specific ids, so we sync each mode. Crafts are
    # byte-identical across modes — we keep a single `regular` set.
    barters =
      Enum.map(EftBuddy.GameMode.all(), fn game_mode ->
        {game_mode, sync_barters_safe(game_mode)}
      end)

    {:ok, %{barters: barters, crafts: sync_crafts_safe()}}
  end

  # ── Price refresh (lightweight, frequent) ──────────────

  @price_compare_keys [
    :avg_24h_price,
    :low_24h_price,
    :high_24h_price,
    :last_low_price
  ]

  # Columns the price tick is allowed to overwrite on conflict.
  @price_replace_fields @price_compare_keys ++ [:updated_at]

  defp do_run_prices do
    Reporter.with_run("PricesSync", fn ->
      with {:ok, regular_raw} <- fetch_flea_prices(EftBuddy.GameMode.default()),
           {:ok, pve_raw} <- fetch_flea_prices("pve") do
        # Legacy regular mirror on the `items` table itself
        # (change-detected, to avoid catalog-wide write churn).
        {:ok, items_summary} = refresh_prices(Repo, regular_raw)

        # Per-mode `item_prices` flea columns — the source of truth the
        # flea market and item-detail reads go through. Full upsert (no
        # change-detection); the row set is bounded (~5k per mode) so the
        # churn is acceptable and the code stays simple. This pass also
        # appends a point to each item's `historical_prices` series (the
        # JSON API has no time series of its own), powering the graphs.
        regular_ip = refresh_item_prices_flea(Repo, regular_raw, "regular")
        pve_ip = refresh_item_prices_flea(Repo, pve_raw, "pve")

        {:ok,
         %{
           items: items_summary,
           item_prices: %{"regular" => regular_ip, "pve" => pve_ip}
         }}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Parameterized flea-price fetch via the JSON API. Returns only the
  # volatile flea columns (no vendors / translation); see
  # `EftBuddy.TarkovApi.flea_prices/1`.
  defp fetch_flea_prices(game_mode) do
    EftBuddy.TarkovApi.flea_prices(game_mode)
  end

  # Change-detecting price update: load the current price columns for
  # every regular item, compare against the snapshot, and bulk-upsert
  # ONLY the rows whose prices actually moved. New items the full sync
  # hasn't created yet are skipped (we never insert here — the next full
  # tick owns creation). Returns `{:ok, %{checked: n, updated: m}}`.
  defp refresh_prices(repo, raw) do
    incoming = Enum.filter(raw, &match?(%{"id" => id} when is_binary(id), &1))

    existing =
      from(i in Item,
        where: i.is_quest_item == false,
        select:
          {i.external_id,
           %{
             id: i.id,
             name: i.name,
             normalized_name: i.normalized_name,
             avg_24h_price: i.avg_24h_price,
             low_24h_price: i.low_24h_price,
             high_24h_price: i.high_24h_price,
             last_low_price: i.last_low_price
           }}
      )
      |> repo.all()
      |> Map.new()

    now = now_naive()

    rows =
      Enum.flat_map(incoming, fn item ->
        case Map.get(existing, item["id"]) do
          nil ->
            []

          current ->
            new_prices = %{
              avg_24h_price: item["avg24hPrice"],
              low_24h_price: item["low24hPrice"],
              high_24h_price: item["high24hPrice"],
              last_low_price: item["lastLowPrice"]
            }

            if prices_changed?(current, new_prices) do
              # Re-supply the NOT NULL identity columns so the (never
              # taken) insert branch of ON CONFLICT is still valid; on
              # conflict only @price_replace_fields are overwritten.
              [
                Map.merge(new_prices, %{
                  id: current.id,
                  external_id: item["id"],
                  name: current.name,
                  normalized_name: current.normalized_name,
                  inserted_at: now,
                  updated_at: now
                })
              ]
            else
              []
            end
        end
      end)

    # Guarded too, even though the flea read path no longer consults these
    # columns. `prices_changed?/2` treats `nil != 123` as a change, so a
    # null-stripped document writes the nulls here exactly as it would to
    # `item_prices` — and leaving a known catalogue-nulling write unguarded
    # because "nothing reads it today" is how it gets read again.
    #
    # The counts are free here: `existing` already selected `last_low_price`.
    current_priced = Enum.count(existing, fn {_ext, cur} -> cur.last_low_price != nil end)
    incoming_priced = Enum.count(incoming, &(&1["lastLowPrice"] != nil))

    case prices_safe?(current_priced, incoming_priced) do
      {:skip, reason} ->
        Logger.error(
          "[#{Reporter.colorize_label("PricesSync")}] Refusing the legacy items-table " <>
            "price mirror: #{reason}. Keeping existing prices."
        )

        {:ok, %{checked: length(incoming), updated: 0, refused: true}}

      :ok ->
        updated =
          rows
          |> Enum.chunk_every(2_000)
          |> Enum.reduce(0, fn chunk, acc ->
            {count, _} =
              repo.insert_all(Item, chunk,
                on_conflict: {:replace, @price_replace_fields},
                conflict_target: :external_id
              )

            acc + count
          end)

        {:ok, %{checked: length(incoming), updated: updated}}
    end
  end

  defp prices_changed?(current, new_prices) do
    Enum.any?(@price_compare_keys, fn key ->
      Map.get(current, key) != Map.get(new_prices, key)
    end)
  end

  # Bounded window of price-history points kept per item per mode. The
  # price tick appends one point each run (~15 min by default), so this
  # is ~48h of history at the default cadence — enough for the flea-card
  # sparkline and the item-detail graph without unbounded column growth.
  @max_history_points 192

  # Upsert the volatile flea columns of `item_prices` for one game mode
  # AND append a price-history point built from this same JSON snapshot.
  #
  # tarkov.dev's JSON API carries only the *spot* flea fields — there is
  # no time series anywhere in it — so we accumulate the history
  # ourselves: each run appends a `%{"price" => lastLowPrice,
  # "timestamp" => now_ms}` point to the item's `historical_prices` array
  # and trims it to the most recent `@max_history_points`. Items without
  # a `lastLowPrice` this run keep their existing series untouched. This
  # is what powers the flea-card sparkline / item-detail graph now that
  # we're JSON-only (it fills in over time rather than back-filling).
  #
  # Resolves each API item id to its local item UUID; items the entity
  # sync hasn't created yet are skipped (we never want a dangling FK).
  # On conflict we replace the flea columns + `historical_prices` +
  # `updated_at`, leaving `base_price` (owned by the 6-hourly full pass)
  # untouched. Returns `%{checked: n, upserted: m}`.
  #
  # Guarded by `prices_safe?/2`, because that replace list makes this write
  # destructive: a nil `lastLowPrice` goes over a live price as a NULL, so a
  # full-size document with its price fields stripped wipes the catalogue without
  # changing the row count. See the guard's own docstring.
  @doc false
  # Public only so the guard can be unit-tested — this path had no test coverage
  # at all. Treat it as private; `cleanup_stale/2` above is public for the same
  # reason.
  def refresh_item_prices_flea(repo, raw, game_mode) do
    item_map = fetch_item_map(repo)
    history_map = fetch_history_map(repo, game_mode)
    now = now_naive()
    now_ms = System.system_time(:millisecond)

    rows =
      Enum.flat_map(raw, fn item ->
        case Map.get(item_map, item["id"]) do
          nil ->
            []

          item_id ->
            prev = Map.get(history_map, item_id)

            [
              %{
                id: Ecto.UUID.generate(),
                item_id: item_id,
                game_mode: game_mode,
                base_price: nil,
                last_low_price: item["lastLowPrice"],
                avg_24h_price: item["avg24hPrice"],
                low_24h_price: item["low24hPrice"],
                high_24h_price: item["high24hPrice"],
                historical_prices: append_history(prev, item["lastLowPrice"], now_ms),
                inserted_at: now,
                updated_at: now
              }
            ]
        end
      end)

    replace = [
      :last_low_price,
      :avg_24h_price,
      :low_24h_price,
      :high_24h_price,
      :historical_prices,
      :updated_at
    ]

    incoming_priced = Enum.count(rows, &(&1.last_low_price != nil))

    current_priced =
      repo.aggregate(
        from(p in ItemPrice, where: p.game_mode == ^game_mode and not is_nil(p.last_low_price)),
        :count,
        :id
      )

    case prices_safe?(current_priced, incoming_priced) do
      {:skip, reason} ->
        # The WHOLE mode's write is abandoned, not just the nil rows. Writing only
        # the priced ones would mean a legitimate delisting never lands — prices
        # would freeze at their last value forever with no signal — and it would
        # make the failure partial, so some prices update and some do not and
        # nobody can tell which. Refusing leaves the previous complete snapshot
        # intact at a cost of one ten-minute tick of staleness, and shouts.
        #
        # Per mode, so a bad PVE document cannot block a good PVP one.
        Logger.error(
          "[#{Reporter.colorize_label("PricesSync")}] Refusing #{game_mode} price write: " <>
            "#{reason}. Keeping existing prices."
        )

        %{checked: length(raw), upserted: 0, refused: true}

      :ok ->
        upserted =
          rows
          |> Enum.chunk_every(2_000)
          |> Enum.reduce(0, fn chunk, acc ->
            {count, _} =
              repo.insert_all(ItemPrice, chunk,
                on_conflict: {:replace, replace},
                conflict_target: [:item_id, :game_mode]
              )

            acc + count
          end)

        %{checked: length(raw), upserted: upserted}
    end
  end

  # Map of `item_id => historical_prices` for one mode, so the price tick
  # can append to each item's existing series in one pass.
  defp fetch_history_map(repo, game_mode) do
    from(p in ItemPrice,
      where: p.game_mode == ^game_mode,
      select: {p.item_id, p.historical_prices}
    )
    |> repo.all()
    |> Map.new()
  end

  # Append a `{price, timestamp}` point to `prev` (the item's existing
  # series) and trim to the most recent `@max_history_points`. A nil /
  # non-integer price — the item isn't on the flea this run — leaves the
  # series unchanged. Always returns a list (never nil) so the jsonb
  # column dumps cleanly.
  defp append_history(prev, price, now_ms) when is_integer(price) do
    prev = if is_list(prev), do: prev, else: []

    (prev ++ [%{"price" => price, "timestamp" => now_ms}])
    |> Enum.take(-@max_history_points)
  end

  defp append_history(prev, _price, _now_ms), do: if(is_list(prev), do: prev, else: [])

  # ── Flea settings ──────────────────────────────────────

  # Sync the global flea-market unlock level
  # (`fleaMarket.minPlayerLevel`) into `game_settings`. Mode-agnostic, so
  # we read it once from the default mode. Wrapped like the other safe
  # sub-steps so a transient failure logs but never rolls back the items
  # pipeline.
  defp sync_flea_settings_safe do
    result =
      try do
        sync_flea_settings()
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] FleaSettings crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {:error, {:crash, Exception.message(e)}}
      end

    case result do
      {:ok, summary} -> Logger.info("[#{prefix()}] FleaSettings synced: #{inspect(summary)}")
      {:error, reason} -> Logger.error("[#{prefix()}] FleaSettings error: #{inspect(reason)}")
    end

    result
  end

  defp sync_flea_settings do
    # Wrap the DB work in a Reporter run (like PricesSync / QuestItemsSync)
    # so the `game_settings` upsert's queries roll up into a single
    # `[FleaSettingsSync] …` summary line. Without this, the SELECT inside
    # `GameSettings.put_int/2` runs outside any tracked run and the
    # Reporter's out-of-run fallback leaks a raw `[debug] QUERY OK
    # source=game_settings …` line into the sync output. run_sync's /
    # PricesSync's own runs have already exited by the time this is called
    # (see do_run_items), so with_run is not nested here.
    Reporter.with_run("FleaSettingsSync", fn ->
      case EftBuddy.TarkovApi.flea_market(EftBuddy.GameMode.default()) do
        {:ok, fm} ->
          level = fm["minPlayerLevel"]
          EftBuddy.GameSettings.put_int(EftBuddy.Items.flea_unlock_level_key(), level)
          {:ok, %{flea_market_min_player_level: level}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # items multi; if that succeeds, run quest items in the same
  # locked window so they're in the items table before Tasks.Sync
  # tries to resolve obj['questItem'] refs against it.
  defp do_run_items do
    case run_sync() do
      {:ok, count} ->
        # Per-mode economy: item_prices + sell_for/buy_for for BOTH
        # PVP (regular) and PVE. `run_sync/0` above only writes the
        # `items` table (entity columns + the regular flea-price
        # mirror); these passes own the mode-aware price surface that
        # every flea-market and item-detail read goes through. Each is
        # wrapped (sync_prices_safe) so one mode failing (a transient
        # API issue) doesn't roll back the other or the entity sync.
        Enum.each(EftBuddy.GameMode.all(), &sync_prices_safe/1)
        # The global flea unlock level (`fleaMarket.minPlayerLevel`) — the
        # hard floor the flea lock uses. Mode-agnostic (same for PVP/PVE),
        # so synced once. Must run *after* prices so the value is fresh
        # alongside the per-mode rows it gates.
        _ = sync_flea_settings_safe()
        _ = sync_quest_items_safe()
        {:ok, count}

      other ->
        other
    end
  end

  # Quest-items wrapper for the same logging contract as
  # sync_barters_safe / sync_crafts_safe. Returns the underlying
  # `{:ok, count} | {:error, reason}` so the caller can fold it
  # into the run summary if/when we extend the structured result.
  defp sync_quest_items_safe do
    result =
      try do
        sync_quest_items()
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] QuestItems crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {:error, {:crash, Exception.message(e)}}
      end

    case result do
      {:ok, count} -> Logger.info("[#{prefix()}] QuestItems upserted: #{count}")
      {:error, reason} -> Logger.error("[#{prefix()}] QuestItems error: #{inspect(reason)}")
    end

    result
  end

  # Pulls the QuestItem type from tarkov.dev and writes rows into
  # the items table with is_quest_item=true. Re-runnable (upserts
  # on external_id; null/empty fields are kept fresh on every run).
  defp sync_quest_items do
    # Wrap the work in a Reporter run, same as run_sync (ItemsSync),
    # sync_barters (BartersSync) and sync_crafts (CraftsSync). Without
    # this, the upsert/prune queries below execute with no run flag
    # set in the process dictionary, so the telemetry handler falls
    # through to its "outside a run" branch and emits a noisy per-query
    # Ecto-style debug line for every one of them. This runs *after*
    # run_sync's own with_run has already exited (see do_run_full /
    # do_run_items), so there's no nesting: with_run is not re-entrant.
    Reporter.with_run("QuestItemsSync", fn ->
      case fetch_quest_items() do
        {:ok, []} ->
          {:ok, 0}

        {:ok, quest_items} when is_list(quest_items) ->
          upsert_quest_items(Repo, quest_items)

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp fetch_quest_items do
    EftBuddy.TarkovApi.quest_items()
  end

  defp upsert_quest_items(repo, quest_items) do
    now = now_naive()

    rows =
      Enum.map(quest_items, fn qi ->
        %{
          id: Ecto.UUID.generate(),
          external_id: qi["id"],
          name: qi["name"],
          short_name: qi["shortName"],
          # The QuestItem type doesn't expose normalizedName, so we
          # derive a reasonable slug from the name. Used by
          # `/items?q=<slug>` link-throughs and any future scopes.
          normalized_name: slugify(qi["name"]),
          description: qi["description"],
          icon_link: qi["iconLink"],
          grid_image_link: qi["gridImageLink"],
          base_image_link: qi["baseImageLink"],
          image_512px_link: qi["image512pxLink"],
          is_quest_item: true,
          # Everything below stays nil for quest items: they don't
          # trade, don't have a category, and don't have a tier
          # color. The Items page already nil-guards on these.
          base_price: nil,
          avg_24h_price: nil,
          low_24h_price: nil,
          high_24h_price: nil,
          last_low_price: nil,
          wiki_link: nil,
          link: nil,
          inspect_image_link: nil,
          image_8x_link: nil,
          background_color: nil,
          category_id: nil,
          contains_item_id: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        # Fields we want to keep fresh on every sync. Crucially we
        # also force `is_quest_item` to true — otherwise a row that
        # was created as a regular item (theoretical, since external
        # ids don't collide today) wouldn't get reclassified. Same
        # principle as the regular items upsert: every API-driven
        # field is replace-on-conflict, identity columns are not.
        replace_fields = [
          :name,
          :short_name,
          :normalized_name,
          :description,
          :icon_link,
          :grid_image_link,
          :base_image_link,
          :image_512px_link,
          :is_quest_item,
          :updated_at
        ]

        total =
          rows
          |> Enum.chunk_every(2_000)
          |> Enum.reduce(0, fn chunk, acc ->
            {count, _} =
              repo.insert_all(Item, chunk,
                on_conflict: {:replace, replace_fields},
                conflict_target: :external_id
              )

            acc + count
          end)

        # Prune quest items the API no longer returns. Scoped to
        # is_quest_item == true so this only ever touches rows this
        # function owns — never a regular item. We keep this here
        # (rather than in cleanup_stale) precisely because the upsert
        # above conflicts on external_id and therefore *preserves* the
        # UUID of every surviving quest item; deleting only the truly
        # stale ones means the questItem UUIDs stored in objective
        # payloads stay valid across syncs.
        valid_external_ids = Enum.map(quest_items, & &1["id"])

        # GUARDED, like every other prune in this application. It was not, and the
        # reasoning that left it unguarded was subtly wrong: the note used to say
        # `quest_items` is always non-empty here, since `sync_quest_items` returns
        # `{:ok, 0}` on an empty response without calling this — which is true, and
        # irrelevant. EMPTY was never the dangerous case. A truncated-but-HTTP-200
        # response carrying 1 of 40 quest items passes that check happily and deletes
        # the other 39.
        #
        # And quest items are an expensive thing to delete: `items.id` is referenced
        # with `on_delete: :delete_all` by `task_item_rewards` and
        # `task_offer_unlocks`, and the questItem UUIDs are baked into task objective
        # payloads as JSONB — which no FK protects and only `Tasks.Sync` rebuilds, at
        # boot. So a truncated quest-item fetch silently strips task rewards and
        # dangles objective references until the next full boot sequence.
        current = repo.aggregate(from(i in Item, where: i.is_quest_item == true), :count, :id)

        case cleanup_safe?(current, length(valid_external_ids)) do
          {:skip, reason} ->
            Logger.error(
              "[#{prefix()}] Refusing stale quest-item cleanup: #{reason}. Keeping existing rows."
            )

          :ok ->
            from(i in Item,
              where: i.is_quest_item == true and i.external_id not in ^valid_external_ids
            )
            |> repo.delete_all()
        end

        {:ok, total}
    end
  end

  # ── Sub-step wrappers (logging + result normalisation) ─

  # Per-mode price + vendor pass wrapper. Mirrors sync_barters_safe:
  # contains crashes, logs one uniform line, and returns the underlying
  # result so the caller (do_run_items) can keep going to the next mode.
  defp sync_prices_safe(game_mode) do
    result =
      try do
        sync_prices_for_mode(game_mode)
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] Prices(#{game_mode}) crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {:error, {:crash, Exception.message(e)}}
      end

    case result do
      {:ok, count} ->
        Logger.info("[#{prefix()}] Prices(#{game_mode}) upserted: #{inspect(count)}")

      {:skip, reason} ->
        Logger.info("[#{prefix()}] Skipped prices(#{game_mode}): #{reason}")

      {:error, reason} ->
        Logger.error("[#{prefix()}] Prices(#{game_mode}) error: #{inspect(reason)}")
    end

    result
  end

  # Returns the original `{:ok, count} | {:skip, reason} | {:error, reason}`
  # tuple so callers can build a structured summary, while still
  # logging a single uniform line per outcome.
  defp sync_barters_safe(game_mode) do
    result =
      try do
        sync_barters(game_mode)
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] Barters(#{game_mode}) crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {:error, {:crash, Exception.message(e)}}
      end

    case result do
      {:ok, _count} ->
        :ok

      {:skip, reason} ->
        Logger.info("[#{prefix()}] Skipped barters(#{game_mode}): #{reason}")

      {:error, reason} ->
        Logger.error("[#{prefix()}] Barters(#{game_mode}) error: #{inspect(reason)}")
    end

    result
  end

  defp sync_crafts_safe do
    result =
      try do
        sync_crafts()
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] Crafts crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
          )

          {:error, {:crash, Exception.message(e)}}
      end

    case result do
      {:ok, _count} -> :ok
      {:skip, reason} -> Logger.info("[#{prefix()}] Skipped crafts: #{reason}")
      {:error, reason} -> Logger.error("[#{prefix()}] Crafts error: #{inspect(reason)}")
    end

    result
  end

  # ── Cluster-wide lock helper ───────────────────────────

  # `:global.set_lock/3` is cluster-wide and re-entrant per-pid; we
  # only ever hold it for the duration of a single `run*/0` call so
  # the cluster sees at most one Items.Sync run in flight at once.
  # Same shape as `EftBuddy.Tasks.Sync`.
  defp with_global_lock(fun) do
    nodes = [node() | Node.list()]

    case :global.set_lock(@lock_id, nodes, 0) do
      true ->
        try do
          fun.()
        after
          :global.del_lock(@lock_id, nodes)
        end

      false ->
        Logger.info("[#{prefix()}] Skipped: another sync is already running.")
        {:error, :already_running}
    end
  end

  defp jitter(interval) when is_integer(interval) and interval > 0 do
    :rand.uniform(div(interval, 10) + 1)
  end

  defp jitter(_), do: 0

  # Colorized tag for this GenServer's own orchestration lines (the
  # `[Sync]` wrapper around the periodic ticks). The per-pipeline summary
  # lines (ItemsSync / PricesSync / …) are already colored by the Reporter;
  # this keeps the wrapper lines consistent with them.
  defp prefix, do: Reporter.colorize_label("Sync")

  # `Process.send_after/3` only accepts non-negative integers; coerce just in
  # case a config value comes through as a float or a binary. `default` is the
  # interval-specific fallback used when the value is unusable.
  defp normalize_ms(value, _default) when is_integer(value) and value >= 0, do: value
  defp normalize_ms(value, _default) when is_float(value) and value >= 0.0, do: trunc(value)

  defp normalize_ms(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 0 ->
        n

      _ ->
        Logger.warning(
          "[#{prefix()}] Ignoring unparseable interval #{inspect(value)}; using default #{default}ms"
        )

        default
    end
  end

  defp normalize_ms(value, default) do
    Logger.warning(
      "[#{prefix()}] Ignoring invalid interval #{inspect(value)}; using default #{default}ms"
    )

    default
  end

  # ── Pipeline ───────────────────────────────────────────

  defp run_sync do
    Reporter.with_run("ItemsSync", fn ->
      case fetch_items() do
        {:ok, raw_items} ->
          items = sanitize_items(raw_items)

          case upsert_all(items) do
            {:ok, _} ->
              {:ok, length(items)}

            {:error, _, reason, _} ->
              {:error, reason}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp fetch_items do
    EftBuddy.TarkovApi.items(EftBuddy.GameMode.default())
  end

  # Drop entries that are missing the bits we depend on so later code
  # never sees `nil["..."]`.
  defp sanitize_items(items) do
    items
    |> Enum.filter(fn
      %{"id" => id, "name" => _, "category" => %{"id" => cat_id}}
      when is_binary(id) and is_binary(cat_id) ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn item ->
      item
      |> Map.update("sellFor", [], &reject_nil_vendor/1)
      |> Map.update("buyFor", [], &reject_nil_vendor/1)
    end)
  end

  defp reject_nil_vendor(nil), do: []

  defp reject_nil_vendor(prices) when is_list(prices) do
    Enum.filter(prices, fn
      %{"vendor" => %{"name" => name}} when is_binary(name) -> true
      _ -> false
    end)
  end

  # ── Transaction ────────────────────────────────────────

  defp upsert_all(items) do
    Ecto.Multi.new()
    # 1. Categories first — they're FK targets for items.
    |> Ecto.Multi.run(:insert_categories, fn repo, _ ->
      insert_categories(repo, items)
    end)
    |> Ecto.Multi.run(:category_map, fn repo, _ ->
      {:ok, fetch_category_map(repo)}
    end)
    # 2. Vendors next — FK targets for sell_for / buy_for.
    |> Ecto.Multi.run(:insert_vendors, fn repo, _ ->
      insert_vendors(repo, items)
    end)
    |> Ecto.Multi.run(:vendor_map, fn repo, _ ->
      {:ok, fetch_vendor_map(repo)}
    end)
    # 3. Items — single bulk upsert keyed on :external_id.
    |> Ecto.Multi.run(:upsert_items, fn repo, %{category_map: category_map} ->
      upsert_items(repo, items, category_map)
    end)
    |> Ecto.Multi.run(:item_map, fn repo, _ ->
      {:ok, fetch_item_map(repo)}
    end)
    # 3b. Populate `contains_item_id` for ammo boxes. Has to come
    # after `:item_map` because we need every item's UUID resolved
    # before we can wire boxes to their contained rounds. Runs as
    # its own step so a failure here doesn't mask a price-import
    # failure (or vice-versa).
    |> Ecto.Multi.run(:set_contains_item_id, fn repo, %{item_map: item_map} ->
      set_contains_item_id(repo, items, item_map)
    end)
    # 4. Drop items no longer in the API. Their per-mode prices
    #    (sell_for / buy_for / item_prices rows) cascade away via the
    #    FK `on_delete`. Vendor sell/buy rows and the per-mode
    #    `item_prices` are now populated by `sync_prices_for_mode/1`,
    #    which runs once per game mode right after this entity pass.
    |> Ecto.Multi.run(:cleanup, fn repo, _ ->
      cleanup_stale(repo, items)
    end)
    |> Repo.transaction(timeout: 120_000)
  end

  # ── Categories ─────────────────────────────────────────

  defp insert_categories(repo, items) do
    now = now_naive()

    rows =
      items
      |> Enum.map(& &1["category"])
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(fn cat ->
        %{
          id: Ecto.UUID.generate(),
          external_id: cat["id"],
          name: cat["name"],
          normalized_name: cat["normalizedName"],
          image_link: cat["imageLink"],
          min_level_for_flea_market: cat["minLevelForFlea"],
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          repo.insert_all(Category, rows,
            on_conflict:
              {:replace,
               [:name, :normalized_name, :image_link, :min_level_for_flea_market, :updated_at]},
            conflict_target: :external_id
          )

        {:ok, count}
    end
  end

  defp fetch_category_map(repo) do
    from(c in Category, select: {c.external_id, c.id})
    |> repo.all()
    |> Map.new()
  end

  # ── Vendors ────────────────────────────────────────────

  defp insert_vendors(repo, items) do
    now = now_naive()

    rows =
      items
      |> Enum.flat_map(fn item -> item["sellFor"] ++ item["buyFor"] end)
      |> Enum.map(& &1["vendor"])
      |> Enum.uniq_by(& &1["name"])
      |> Enum.map(fn vendor ->
        %{
          id: Ecto.UUID.generate(),
          name: vendor["name"],
          normalized_name: vendor["normalizedName"],
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          repo.insert_all(Vendor, rows,
            on_conflict: {:replace, [:normalized_name, :updated_at]},
            conflict_target: :name
          )

        {:ok, count}
    end
  end

  defp fetch_vendor_map(repo) do
    from(v in Vendor, select: {v.name, v.id})
    |> repo.all()
    |> Map.new()
  end

  # ── Items ──────────────────────────────────────────────

  defp upsert_items(repo, items, category_map) do
    now = now_naive()

    rows =
      Enum.map(items, fn item ->
        %{
          id: Ecto.UUID.generate(),
          external_id: item["id"],
          name: item["name"],
          short_name: item["shortName"],
          normalized_name: item["normalizedName"],
          description: item["description"],
          base_price: item["basePrice"],
          avg_24h_price: item["avg24hPrice"],
          low_24h_price: item["low24hPrice"],
          high_24h_price: item["high24hPrice"],
          wiki_link: item["wikiLink"],
          link: item["link"],
          icon_link: item["iconLink"],
          grid_image_link: item["gridImageLink"],
          base_image_link: item["baseImageLink"],
          inspect_image_link: item["inspectImageLink"],
          image_512px_link: item["image512pxLink"],
          image_8x_link: item["image8xLink"],
          background_color: item["backgroundColor"],
          min_level_for_flea: item["minLevelForFlea"],
          last_low_price: item["lastLowPrice"],
          category_id: Map.get(category_map, item["category"]["id"]),
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        replace_fields = [
          :name,
          :short_name,
          :normalized_name,
          :description,
          :base_price,
          :avg_24h_price,
          :low_24h_price,
          :high_24h_price,
          :wiki_link,
          :link,
          :icon_link,
          :grid_image_link,
          :base_image_link,
          :inspect_image_link,
          :image_512px_link,
          :image_8x_link,
          :background_color,
          :min_level_for_flea,
          :last_low_price,
          :category_id,
          :updated_at
        ]

        # Chunk to keep parameter count under Postgres' 65535 limit.
        # ~22 fields per row → 5000 rows ≈ 110k params, so chunk smaller.
        total =
          rows
          |> Enum.chunk_every(2_000)
          |> Enum.reduce(0, fn chunk, acc ->
            {count, _} =
              repo.insert_all(Item, chunk,
                on_conflict: {:replace, replace_fields},
                conflict_target: :external_id
              )

            acc + count
          end)

        {:ok, total}
    end
  end

  defp fetch_item_map(repo) do
    from(i in Item, select: {i.external_id, i.id})
    |> repo.all()
    |> Map.new()
  end

  # ── Contained items ────────────────────────────────────
  #
  # Wire ammo-box → ammo-round relationships into the items table
  # so the BARTER ITEMS / CRAFTED ITEMS scope filters can dedupe
  # the round + box pair. tarkov.dev encodes the same in-game ammo
  # barter at *both* the box id ("Pack of .300 Blackout CBJ ammo")
  # and the round id (".300 Blackout CBJ"); without this column
  # both rows show up in the BARTER ITEMS tab as separate entries
  # even though they represent the same trade.
  #
  # Strategy: blanket-reset every item's `contains_item_id` to nil
  # first so a box that's no longer a single-content container (or
  # an item that was reclassified) doesn't keep a stale pointer,
  # then write fresh pointers for every box in the current snapshot.
  # Two statements; both run inside the same Multi transaction so a
  # mid-sync failure can't leave the column half-populated.
  #
  # Single-content rule: we only set `contains_item_id` when the
  # API returns *exactly one* `containsItems` entry. That shape
  # cleanly identifies the ammo-pack pattern (one entry pointing
  # to the round) and excludes weapon presets / pre-built guns,
  # which have many entries (one per part). The corner case is a
  # sealed-case style item that wraps exactly one inner item — if
  # both the case and the inner item ever both have barters at
  # the same trader, our rule would dedupe them. We haven't seen
  # that happen in the live data, and if it does we can tighten
  # the rule with a category-name filter on the contained item.
  defp set_contains_item_id(repo, items, item_map) do
    repo.update_all(Item, set: [contains_item_id: nil])

    pairs =
      items
      |> Enum.flat_map(fn item ->
        with box_uuid when is_binary(box_uuid) <- Map.get(item_map, item["id"]),
             contained_ext_id when is_binary(contained_ext_id) <-
               sole_contained_item_id(item),
             contained_uuid when is_binary(contained_uuid) <-
               Map.get(item_map, contained_ext_id) do
          [{box_uuid, contained_uuid}]
        else
          _ -> []
        end
      end)

    # One UPDATE per box. Single-content containers are a small
    # bounded set (~100s, growing slowly with the game), so the
    # per-row cost is negligible vs. the complexity of building a
    # single CASE-when bulk update — keep the simple shape.
    Enum.each(pairs, fn {box_uuid, contained_uuid} ->
      from(i in Item, where: i.id == ^box_uuid)
      |> repo.update_all(set: [contains_item_id: contained_uuid])
    end)

    {:ok, length(pairs)}
  end

  # Returns the single contained item's external_id when an item's
  # `containsItems` is a list with exactly one entry, `nil`
  # otherwise. The list-of-one shape is what ammo packs have (one
  # round) and what we want to dedupe; multi-entry shapes (weapon
  # presets / pre-built guns) and empty shapes (regular items)
  # both yield nil so the caller skips them. Defensive against
  # missing / non-list values from the API.
  defp sole_contained_item_id(%{"containsItems" => [%{"item" => %{"id" => id}}]})
       when is_binary(id),
       do: id

  defp sole_contained_item_id(_), do: nil

  # ── Prices ─────────────────────────────────────────────

  # Replace strategy: for every item in the snapshot, delete its old price
  # rows *for this game mode* in this table, then bulk-insert the new ones.
  # Atomic within the transaction. Scoping the delete by `game_mode` is
  # what lets the regular and PVE passes coexist — the PVE pass must not
  # wipe the regular rows and vice-versa. Items not in the snapshot keep
  # their rows here (they'll be removed by `cleanup_stale/2`).
  defp replace_prices(repo, items, item_map, vendor_map, kind, schema, game_mode) do
    now = now_naive()
    field = if kind == :sell, do: "sellFor", else: "buyFor"

    rows =
      items
      |> Enum.flat_map(fn item ->
        item_id = Map.get(item_map, item["id"])

        if item_id do
          (item[field] || [])
          |> Enum.flat_map(fn price ->
            vendor_id = Map.get(vendor_map, price["vendor"]["name"])

            if vendor_id do
              [
                %{
                  id: Ecto.UUID.generate(),
                  price: price["price"],
                  price_rub: price["priceRUB"],
                  currency: price["currency"],
                  game_mode: game_mode,
                  item_id: item_id,
                  vendor_id: vendor_id,
                  inserted_at: now,
                  updated_at: now
                }
              ]
            else
              []
            end
          end)
        else
          []
        end
      end)

    item_ids =
      items
      |> Enum.map(&Map.get(item_map, &1["id"]))
      |> Enum.reject(&is_nil/1)

    # Delete in chunks to keep IN (...) list manageable. Scoped to this
    # mode so the sibling mode's rows survive.
    item_ids
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      from(p in schema, where: p.item_id in ^chunk and p.game_mode == ^game_mode)
      |> repo.delete_all()
    end)

    # The Tarkov API can return more than one price entry for the same
    # (item, vendor) pair (e.g. multiple currencies, or Fence quirks).
    # Collapse to a single row per pair so we don't double-list a vendor
    # for one item. We keep the row with the lowest `priceRUB` so
    # downstream "best price" queries stay correct; ties fall back to
    # whichever row we saw first.
    deduped_rows =
      rows
      |> Enum.group_by(&{&1.item_id, &1.vendor_id})
      |> Enum.map(fn {_key, group} ->
        Enum.min_by(group, fn row -> row.price_rub || :infinity end)
      end)

    inserted =
      deduped_rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} = repo.insert_all(schema, chunk)
        acc + count
      end)

    {:ok, inserted}
  end

  # ── Per-mode prices + vendors ──────────────────────────

  # The structural per-mode economy pass: fetch the full price + vendor
  # snapshot for `game_mode`, then upsert `item_prices` and replace the
  # `sell_for` / `buy_for` rows for that mode. Runs once per mode right
  # after the entity sync (`do_run_items`). Vendors are upserted from
  # this snapshot too so a PVE-only vendor (none today, but cheap
  # insurance) still resolves.
  defp sync_prices_for_mode(game_mode) do
    Reporter.with_run("PricesSync:#{game_mode}", fn ->
      case EftBuddy.TarkovApi.items(game_mode) do
        {:ok, raw} ->
          items = sanitize_price_items(raw)

          Repo.transaction(
            fn ->
              insert_vendors(Repo, items)
              item_map = fetch_item_map(Repo)
              vendor_map = fetch_vendor_map(Repo)

              {:ok, prices} = upsert_item_prices(Repo, items, item_map, game_mode)

              {:ok, sell} =
                replace_prices(Repo, items, item_map, vendor_map, :sell, SellFor, game_mode)

              {:ok, buy} =
                replace_prices(Repo, items, item_map, vendor_map, :buy, BuyFor, game_mode)

              %{prices: prices, sell_for: sell, buy_for: buy}
            end,
            timeout: 120_000
          )
          |> case do
            {:ok, counts} -> {:ok, counts}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # The price query doesn't fetch `category` (entity-owned), so the
  # entity sanitizer's category guard doesn't apply here. We only need a
  # binary id and clean vendor refs on the price rows.
  defp sanitize_price_items(items) do
    items
    |> Enum.filter(&match?(%{"id" => id} when is_binary(id), &1))
    |> Enum.map(fn item ->
      item
      |> Map.update("sellFor", [], &reject_nil_vendor/1)
      |> Map.update("buyFor", [], &reject_nil_vendor/1)
    end)
  end

  # Upsert one `item_prices` row per item for this mode (base_price +
  # the volatile flea columns). Items the entity sync hasn't created
  # yet are skipped (no dangling FK). On conflict every price column is
  # replaced.
  defp upsert_item_prices(repo, items, item_map, game_mode) do
    now = now_naive()

    rows =
      Enum.flat_map(items, fn item ->
        case Map.get(item_map, item["id"]) do
          nil ->
            []

          item_id ->
            [
              %{
                id: Ecto.UUID.generate(),
                item_id: item_id,
                game_mode: game_mode,
                base_price: item["basePrice"],
                last_low_price: item["lastLowPrice"],
                avg_24h_price: item["avg24hPrice"],
                low_24h_price: item["low24hPrice"],
                high_24h_price: item["high24hPrice"],
                inserted_at: now,
                updated_at: now
              }
            ]
        end
      end)

    replace = [
      :base_price,
      :last_low_price,
      :avg_24h_price,
      :low_24h_price,
      :high_24h_price,
      :updated_at
    ]

    total =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          repo.insert_all(ItemPrice, chunk,
            on_conflict: {:replace, replace},
            conflict_target: [:item_id, :game_mode]
          )

        acc + count
      end)

    {:ok, total}
  end

  # ── Cleanup ────────────────────────────────────────────

  @doc false
  # Items absent from the snapshot — and their prices — are removed.
  # Categories and vendors are intentionally left in place because the
  # API frequently lists them transiently and they're cheap to keep.
  #
  # Public only so it can be unit-tested; treat it as private. This is the
  # highest-blast-radius prune in the application: `items.id` is referenced with
  # `on_delete: :delete_all` by `hideout_item_requirements`, `task_item_rewards` and
  # `task_offer_unlocks`, none of which are rebuilt by this sync — so a delete here
  # silently empties hideout station requirements and task rewards. That makes both
  # the guard AND the `is_quest_item == false` scope load-bearing, and both are
  # pinned by `test/eft_buddy/items/sync_cleanup_stale_test.exs`.
  def cleanup_stale(repo, items) do
    valid_ids = Enum.map(items, & &1["id"])

    if valid_ids == [] do
      {:ok, %{items: 0, sell_for: 0, buy_for: 0}}
    else
      # Safety guard: refuse to prune when the snapshot is implausibly
      # small relative to what we already have (a truncated-but-200 API
      # response). `current` counts only regular items because that's
      # the only set this function ever deletes (see the
      # `is_quest_item == false` guard below).
      current = repo.aggregate(from(i in Item, where: i.is_quest_item == false), :count, :id)

      case cleanup_safe?(current, length(valid_ids)) do
        {:skip, reason} ->
          Logger.error(
            "[#{Reporter.colorize_label("ItemsSync")}] Refusing stale item cleanup: #{reason}. Keeping existing rows."
          )

          {:ok, %{items: 0, sell_for: 0, buy_for: 0}}

        :ok ->
          do_cleanup_stale(repo, valid_ids)
      end
    end
  end

  defp do_cleanup_stale(repo, valid_ids) do
    # IMPORTANT: only ever delete *regular* items here. Quest items
    # (is_quest_item == true) live in this same table but are synced
    # from a separate `questItems` GraphQL query, so their
    # external_ids are never present in `valid_ids` (the regular
    # items snapshot). Without the `is_quest_item == false` guard,
    # every regular items sync would delete every quest item — and
    # because sync_quest_items re-inserts them afterwards with
    # freshly generated UUIDs (the rows no longer exist to conflict
    # on), the resolved questItem UUIDs that Tasks.Sync baked into
    # objective payloads would all dangle. Tasks.Sync only runs at
    # boot / manually (not on the periodic items tick), so the
    # payloads keep the old UUIDs and the Tasks page's required-items
    # query stops resolving them — the "quest items vanish after the
    # next sync / on refresh" bug. Quest-item pruning is owned by
    # sync_quest_items, which deletes against its own snapshot.
    stale_item_ids_q =
      from(i in Item,
        where: i.external_id not in ^valid_ids and i.is_quest_item == false,
        select: i.id
      )

    {sell_count, _} =
      from(s in SellFor, where: s.item_id in subquery(stale_item_ids_q))
      |> repo.delete_all()

    {buy_count, _} =
      from(b in BuyFor, where: b.item_id in subquery(stale_item_ids_q))
      |> repo.delete_all()

    {item_count, _} =
      from(i in Item, where: i.external_id not in ^valid_ids and i.is_quest_item == false)
      |> repo.delete_all()

    {:ok, %{items: item_count, sell_for: sell_count, buy_for: buy_count}}
  end

  # ── Barters ────────────────────────────────────────────
  #
  # `sync_barters/0` and `sync_crafts/0` follow the same shape:
  #
  #   1. Fetch the full snapshot from the API.
  #   2. Build resolution maps (item-external-id → uuid, etc.) from
  #      our local DB so we can translate API IDs into FKs.
  #   3. Upsert parents (`items_barters` / `items_crafts`).
  #   4. Replace child rows (`required_items` / `reward_items`) by
  #      deleting the parent's old children and bulk-inserting the
  #      new ones — same replace-strategy `Items.Sync` uses for
  #      sell_for/buy_for.
  #   5. Delete parents whose external_id disappeared from the API
  #      (cascades to children via the FK).
  #
  # Both run in a single transaction so a failure can't leave the
  # tables half-updated.

  defp sync_barters(game_mode) do
    Reporter.with_run("BartersSync:#{game_mode}", fn ->
      with {:ok, raw} <- EftBuddy.TarkovApi.barters(game_mode),
           {:ok, items_map} <- {:ok, fetch_item_map(Repo)},
           {:ok, traders_map} <- {:ok, fetch_trader_map(Repo)},
           {:ok, tasks_map} <- {:ok, fetch_task_map(Repo, game_mode)} do
        barters = sanitize_barters(raw, items_map, traders_map)

        if barters == [] do
          {:skip, "no resolvable barters (hideout/items not yet synced?)"}
        else
          Repo.transaction(
            fn ->
              now = now_naive()

              parent_rows =
                build_barter_parent_rows(barters, traders_map, tasks_map, now, game_mode)

              replace_fields = [:level, :buy_limit, :trader_id, :task_unlock_id, :updated_at]

              parent_rows
              |> Enum.chunk_every(2_000)
              |> Enum.each(fn chunk ->
                Repo.insert_all(Barter, chunk,
                  on_conflict: {:replace, replace_fields},
                  conflict_target: :external_id
                )
              end)

              barter_id_map = fetch_barter_id_map(Repo, game_mode)

              child_required_rows =
                build_barter_child_rows(
                  barters,
                  barter_id_map,
                  items_map,
                  "requiredItems",
                  now,
                  with_attributes: true
                )

              child_reward_rows =
                build_barter_child_rows(
                  barters,
                  barter_id_map,
                  items_map,
                  "rewardItems",
                  now,
                  with_attributes: false
                )

              # Only the parents THIS snapshot carried. `barter_id_map` is read
              # back from the whole table; `replace_children/5` intersects it with
              # THIS run's `parent_rows` so the delete can only ever reach barters
              # upstream actually mentioned — precisely the rows
              # `cleanup_stale_barters/2` below then refuses to prune, which would
              # otherwise leave childless parents. See `replace_children/5`.
              replace_children(
                BarterRequiredItem,
                :barter_id,
                barter_id_map,
                parent_rows,
                child_required_rows
              )

              replace_children(
                BarterRewardItem,
                :barter_id,
                barter_id_map,
                parent_rows,
                child_reward_rows
              )

              cleanup_stale_barters(Enum.map(barters, & &1["id"]), game_mode)

              length(parent_rows)
            end,
            timeout: 120_000
          )
          |> case do
            {:ok, count} -> {:ok, count}
            {:error, reason} -> {:error, reason}
          end
        end
      end
    end)
  end

  defp sanitize_barters(raw, items_map, traders_map) do
    {kept, dropped} =
      Enum.split_with(raw, fn b ->
        with %{"id" => id} when is_binary(id) <- b,
             %{"trader" => %{"normalizedName" => slug}} <- b,
             true <- Map.has_key?(traders_map, slug),
             refs when is_list(refs) <- b["requiredItems"],
             rewards when is_list(rewards) <- b["rewardItems"],
             true <- all_items_resolvable?(refs, items_map),
             true <- all_items_resolvable?(rewards, items_map) do
          true
        else
          _ -> false
        end
      end)

    log_dropped("barters", dropped, items_map, traders_map)
    kept
  end

  defp all_items_resolvable?(list, items_map) do
    Enum.all?(list, fn entry ->
      case entry do
        %{"item" => %{"id" => id}} -> Map.has_key?(items_map, id)
        _ -> false
      end
    end)
  end

  # Surface barters / crafts that `sanitize_*` dropped so a
  # silent filter doesn't hide missing data. Without this the
  # only way to notice a drop was to compare row counts in the
  # DB against the API by hand. We log:
  #
  #   * a one-line summary of how many parents were dropped, and
  #   * up to 5 examples (external_id + reason) so the operator
  #     can immediately tell whether the drops are uniform
  #     ("all dropped because trader X isn't in the DB" =>
  #     hideout sync hasn't run yet) or scattered across
  #     individual missing items ("five different unresolved
  #     items" => the items table is genuinely incomplete).
  #
  # `parent_map_or_traders` is either the traders map (for
  # barters) or the station_level map (for crafts). We only
  # peek at it via `parent_resolution_problem/3`, which
  # branches on the parent kind to phrase the reason
  # appropriately. No-ops cleanly when nothing was dropped.
  defp log_dropped(_kind, [], _items_map, _parent_map), do: :ok

  defp log_dropped(kind, dropped, items_map, parent_map) do
    sample =
      dropped
      |> Enum.take(5)
      |> Enum.map(fn row ->
        ext_id = Map.get(row, "id", "<no-id>")
        reason = drop_reason(kind, row, items_map, parent_map)
        "  - #{ext_id}: #{reason}"
      end)
      |> Enum.join("\n")

    Logger.warning(
      "[#{prefix()}] Skipped #{length(dropped)} #{kind} during sanitisation. First samples:\n" <>
        sample
    )
  end

  # Best-effort one-line explanation per dropped row. We try the
  # cheap structural checks first (shape, parent FK), then fall
  # through to per-item resolution. This intentionally returns
  # *one* reason — the first thing that fails — to keep log lines
  # short; if multiple things are wrong, fixing the first will
  # surface the next on the next sync run.
  defp drop_reason("barters", row, items_map, traders_map) do
    cond do
      not is_map(row) ->
        "row is not a map"

      not is_binary(Map.get(row, "id")) ->
        "missing or non-binary :id"

      get_in(row, ["trader", "normalizedName"]) == nil ->
        "missing trader.normalizedName"

      not Map.has_key?(traders_map, get_in(row, ["trader", "normalizedName"])) ->
        "trader '#{get_in(row, ["trader", "normalizedName"])}' not in DB " <>
          "(hideout sync may not have run yet)"

      not is_list(row["requiredItems"]) ->
        "requiredItems missing or not a list"

      not is_list(row["rewardItems"]) ->
        "rewardItems missing or not a list"

      true ->
        unresolved =
          ((row["requiredItems"] || []) ++ (row["rewardItems"] || []))
          |> Enum.flat_map(&unresolved_item_id(&1, items_map))
          |> Enum.uniq()

        case unresolved do
          [] -> "unknown reason"
          ids -> "unresolved item ids: #{Enum.join(ids, ", ")}"
        end
    end
  end

  defp drop_reason("crafts", row, items_map, station_level_map) do
    cond do
      not is_map(row) ->
        "row is not a map"

      not is_binary(Map.get(row, "id")) ->
        "missing or non-binary :id"

      get_in(row, ["station", "normalizedName"]) == nil ->
        "missing station.normalizedName"

      not is_integer(row["level"]) ->
        "missing or non-integer :level"

      not Map.has_key?(
        station_level_map,
        {get_in(row, ["station", "normalizedName"]), row["level"]}
      ) ->
        "station '#{get_in(row, ["station", "normalizedName"])}' " <>
          "level #{row["level"]} not in DB (hideout sync may not have run yet)"

      not is_list(row["requiredItems"]) ->
        "requiredItems missing or not a list"

      not is_list(row["rewardItems"]) ->
        "rewardItems missing or not a list"

      true ->
        unresolved =
          ((row["requiredItems"] || []) ++ (row["rewardItems"] || []))
          |> Enum.flat_map(&unresolved_item_id(&1, items_map))
          |> Enum.uniq()

        case unresolved do
          [] -> "unknown reason"
          ids -> "unresolved item ids: #{Enum.join(ids, ", ")}"
        end
    end
  end

  # Helper for `drop_reason/4`: returns `[id]` if the entry's
  # item id isn't in `items_map`, `[]` otherwise. Handles the
  # malformed-entry case (no item / no id) by surfacing a
  # placeholder so the caller knows *something* was wrong.
  defp unresolved_item_id(%{"item" => %{"id" => id}}, items_map) do
    if Map.has_key?(items_map, id), do: [], else: [id]
  end

  defp unresolved_item_id(_, _), do: ["<malformed-entry>"]

  defp build_barter_parent_rows(barters, traders_map, tasks_map, now, game_mode) do
    Enum.map(barters, fn b ->
      %{
        id: Ecto.UUID.generate(),
        external_id: b["id"],
        level: b["level"],
        buy_limit: b["buyLimit"],
        game_mode: game_mode,
        trader_id: Map.get(traders_map, b["trader"]["normalizedName"]),
        task_unlock_id: resolve_task_unlock(b["taskUnlock"], tasks_map),
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp build_barter_child_rows(barters, barter_id_map, items_map, key, now, opts) do
    with_attributes = Keyword.fetch!(opts, :with_attributes)

    Enum.flat_map(barters, fn b ->
      barter_id = Map.get(barter_id_map, b["id"])

      if barter_id do
        Enum.map(b[key] || [], fn entry ->
          row = %{
            id: Ecto.UUID.generate(),
            count: trunc_or_nil(entry["count"]),
            quantity: trunc_or_nil(entry["quantity"]),
            barter_id: barter_id,
            item_id: Map.get(items_map, entry["item"]["id"]),
            inserted_at: now,
            updated_at: now
          }

          if with_attributes do
            Map.put(row, :attributes, encode_attributes(entry["attributes"]))
          else
            row
          end
        end)
      else
        []
      end
    end)
    |> Enum.reject(&(is_nil(&1.item_id) or is_nil(&1.count) or is_nil(&1.quantity)))
  end

  # ── Crafts ─────────────────────────────────────────────

  defp sync_crafts do
    Reporter.with_run("CraftsSync", fn ->
      with {:ok, raw} <- EftBuddy.TarkovApi.crafts(),
           {:ok, items_map} <- {:ok, fetch_item_map(Repo)},
           {:ok, station_level_map} <- {:ok, fetch_station_level_map(Repo)},
           {:ok, tasks_map} <- {:ok, fetch_task_map(Repo, EftBuddy.GameMode.default())} do
        crafts = sanitize_crafts(raw, items_map, station_level_map)

        if crafts == [] do
          {:skip, "no resolvable crafts (hideout/items not yet synced?)"}
        else
          Repo.transaction(
            fn ->
              now = now_naive()
              parent_rows = build_craft_parent_rows(crafts, station_level_map, tasks_map, now)

              replace_fields = [:duration, :station_level_id, :task_unlock_id, :updated_at]

              parent_rows
              |> Enum.chunk_every(2_000)
              |> Enum.each(fn chunk ->
                Repo.insert_all(Craft, chunk,
                  on_conflict: {:replace, replace_fields},
                  conflict_target: :external_id
                )
              end)

              craft_id_map = fetch_craft_id_map(Repo)

              child_required_rows =
                build_craft_child_rows(
                  crafts,
                  craft_id_map,
                  items_map,
                  "requiredItems",
                  now,
                  with_attributes: true
                )

              child_reward_rows =
                build_craft_child_rows(
                  crafts,
                  craft_id_map,
                  items_map,
                  "rewardItems",
                  now,
                  with_attributes: false
                )

              # Snapshot-scoped, for the same reason as barters above: unscoped, the
              # delete would strip the children of crafts upstream didn't mention,
              # which `cleanup_stale_parents/2` then declines to prune.
              replace_children(
                CraftRequiredItem,
                :craft_id,
                craft_id_map,
                parent_rows,
                child_required_rows
              )

              replace_children(
                CraftRewardItem,
                :craft_id,
                craft_id_map,
                parent_rows,
                child_reward_rows
              )

              cleanup_stale_parents(Craft, Enum.map(crafts, & &1["id"]))

              length(parent_rows)
            end,
            timeout: 120_000
          )
          |> case do
            {:ok, count} -> {:ok, count}
            {:error, reason} -> {:error, reason}
          end
        end
      end
    end)
  end

  defp sanitize_crafts(raw, items_map, station_level_map) do
    {kept, dropped} =
      Enum.split_with(raw, fn c ->
        with %{"id" => id} when is_binary(id) <- c,
             %{"station" => %{"normalizedName" => slug}} <- c,
             level when is_integer(level) <- c["level"],
             sl_id when is_binary(sl_id) <- Map.get(station_level_map, {slug, level}),
             refs when is_list(refs) <- c["requiredItems"],
             rewards when is_list(rewards) <- c["rewardItems"],
             true <- all_items_resolvable?(refs, items_map),
             true <- all_items_resolvable?(rewards, items_map) do
          true
        else
          _ -> false
        end
      end)

    log_dropped("crafts", dropped, items_map, station_level_map)
    kept
  end

  defp build_craft_parent_rows(crafts, station_level_map, tasks_map, now) do
    Enum.map(crafts, fn c ->
      slug = c["station"]["normalizedName"]
      level = c["level"]

      %{
        id: Ecto.UUID.generate(),
        external_id: c["id"],
        duration: c["duration"] || 0,
        station_level_id: Map.get(station_level_map, {slug, level}),
        task_unlock_id: resolve_task_unlock(c["taskUnlock"], tasks_map),
        inserted_at: now,
        updated_at: now
      }
    end)
  end

  defp build_craft_child_rows(crafts, craft_id_map, items_map, key, now, opts) do
    with_attributes = Keyword.fetch!(opts, :with_attributes)

    Enum.flat_map(crafts, fn c ->
      craft_id = Map.get(craft_id_map, c["id"])

      if craft_id do
        Enum.map(c[key] || [], fn entry ->
          row = %{
            id: Ecto.UUID.generate(),
            count: trunc_or_nil(entry["count"]),
            quantity: trunc_or_nil(entry["quantity"]),
            craft_id: craft_id,
            item_id: Map.get(items_map, entry["item"]["id"]),
            inserted_at: now,
            updated_at: now
          }

          if with_attributes do
            Map.put(row, :attributes, encode_attributes(entry["attributes"]))
          else
            row
          end
        end)
      else
        []
      end
    end)
    |> Enum.reject(&(is_nil(&1.item_id) or is_nil(&1.count) or is_nil(&1.quantity)))
  end

  # ── Shared helpers (barters + crafts) ──────────────────

  @doc false
  # The DB ids of only those parents the current upstream snapshot carried.
  #
  # `id_map` is an `external_id => id` map read back from the WHOLE table (see
  # `fetch_barter_id_map/2` / `fetch_craft_id_map/1`), so it necessarily includes
  # parents upstream did not mention this run. Handing that straight to
  # `replace_children/4` is the bug this function exists to prevent: it deleted
  # every parent's children, including those of the parents `cleanup_safe?/2` then
  # refused to prune, leaving ingredient-less barters and crafts presented to the
  # user as fact.
  #
  # `parent_rows` is built from the snapshot itself, and every row in it has just
  # been upserted, so each `external_id` is guaranteed present in `id_map`.
  #
  # Public only so it can be unit-tested; treat it as private.
  def snapshot_parent_ids(id_map, parent_rows) do
    id_map
    |> Elixir.Map.take(Enum.map(parent_rows, & &1.external_id))
    |> Elixir.Map.values()
  end

  @doc false
  # Replace-strategy bulk insert for child rows: delete the existing children of
  # the parents THIS SNAPSHOT carried, then bulk-insert the fresh set. Avoids
  # needing per-row update detection.
  #
  # It takes `id_map` + `parent_rows` and derives the scope ITSELF rather than
  # accepting a ready-made id list, deliberately. The original defect was a caller
  # passing the full `external_id => id` map read back from the whole table, which
  # deleted the children of every parent — including the ones `cleanup_safe?/2`
  # then refused to prune. The guard's only effect in that case was to leave
  # PARENTS WITH NO CHILDREN: barters and crafts rendering as having no
  # ingredients, which is worse than the missing rows it was protecting against,
  # and is presented to the user as fact.
  #
  # That was a documented contract a caller could still get wrong, on the most
  # destructive DELETE in the application. Now the wrong argument is not
  # expressible: the only thing a caller can hand over is the snapshot itself.
  #
  # Deriving from the snapshot also preserves the case the naive alternative
  # breaks: a parent still present upstream whose child list legitimately became
  # empty must have its stale children cleared, so the scope cannot come from
  # `rows` either.
  #
  # Public only so it can be unit-tested; treat it as private.
  def replace_children(schema, fk, id_map, parent_rows, rows)

  def replace_children(_schema, _fk, _id_map, _parent_rows, []) do
    :ok
  end

  def replace_children(schema, fk, id_map, parent_rows, rows) do
    id_map
    |> snapshot_parent_ids(parent_rows)
    |> Enum.uniq()
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      from(r in schema, where: field(r, ^fk) in ^chunk)
      |> Repo.delete_all()
    end)

    rows
    |> Enum.chunk_every(2_000)
    |> Enum.each(fn chunk ->
      Repo.insert_all(schema, chunk)
    end)
  end

  # Drop parent rows whose external_id is no longer in the API
  # snapshot. Children cascade via the FK's `on_delete: :delete_all`.
  # Guarded by `cleanup_safe?/2` so a truncated upstream response can't
  # wipe the barter/craft tables (and cascade their children away).
  defp cleanup_stale_parents(_schema, []), do: :ok

  defp cleanup_stale_parents(schema, valid_external_ids) do
    current = Repo.aggregate(schema, :count, :id)

    case cleanup_safe?(current, length(valid_external_ids)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale #{inspect(schema)} cleanup: #{reason}. Keeping existing rows."
        )

        :ok

      :ok ->
        from(r in schema, where: r.external_id not in ^valid_external_ids)
        |> Repo.delete_all()

        :ok
    end
  end

  # Barter-specific cleanup. Barters carry a `game_mode` and the two
  # modes' external_id sets are disjoint, so a snapshot for one mode
  # must only prune THAT mode's rows — otherwise syncing `regular` would
  # delete every `pve` barter (its ids aren't in the regular snapshot)
  # and vice-versa. Same partial-snapshot guard as
  # `cleanup_stale_parents/2`, scoped to the mode.
  defp cleanup_stale_barters([], _game_mode), do: :ok

  defp cleanup_stale_barters(valid_external_ids, game_mode) do
    current =
      Repo.aggregate(from(b in Barter, where: b.game_mode == ^game_mode), :count, :id)

    case cleanup_safe?(current, length(valid_external_ids)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale barter cleanup (#{game_mode}): #{reason}. Keeping existing rows."
        )

        :ok

      :ok ->
        from(b in Barter,
          where: b.game_mode == ^game_mode and b.external_id not in ^valid_external_ids
        )
        |> Repo.delete_all()

        :ok
    end
  end

  defp fetch_trader_map(repo) do
    from(t in Trader, select: {t.normalized_name, t.id})
    |> repo.all()
    |> Map.new()
  end

  defp fetch_task_map(repo, game_mode) do
    from(t in TaskRow, where: t.game_mode == ^game_mode, select: {t.external_id, t.id})
    |> repo.all()
    |> Map.new()
  end

  # Map of `{station_slug, level} → station_level_id`. Used to
  # resolve crafts onto the existing hideout schema without
  # duplicating station/level columns.
  defp fetch_station_level_map(repo) do
    from(l in StationLevel,
      join: s in Station,
      on: s.id == l.station_id,
      select: {{s.normalized_name, l.level}, l.id}
    )
    |> repo.all()
    |> Map.new()
  end

  # Scoped to `game_mode` on purpose. The two modes' barter external_id
  # sets are disjoint, so a full-table map would still resolve every
  # child lookup — BUT it's also handed to `replace_children/4`, whose
  # delete step wipes the children of *every* parent id in the map. An
  # unscoped map therefore made the second mode's sync delete the first
  # mode's barter reward/required rows (leaving, e.g., every `regular`
  # barter childless after the `pve` pass), which surfaced as an empty
  # Barter tab / "no barter data" in that mode. Restricting the map to
  # the mode being synced keeps each pass from touching the other's rows.
  defp fetch_barter_id_map(repo, game_mode) do
    from(b in Barter, where: b.game_mode == ^game_mode, select: {b.external_id, b.id})
    |> repo.all()
    |> Map.new()
  end

  defp fetch_craft_id_map(repo) do
    from(c in Craft, select: {c.external_id, c.id})
    |> repo.all()
    |> Map.new()
  end

  defp resolve_task_unlock(nil, _), do: nil
  defp resolve_task_unlock(%{"id" => id}, tasks_map), do: Map.get(tasks_map, id)
  defp resolve_task_unlock(_, _), do: nil

  # The API returns `count`/`quantity` as Float (the GraphQL schema
  # types them as Float!). Our columns are integers because for
  # barters/crafts these are always whole numbers in practice, so
  # truncate. Defensive: anything non-numeric becomes nil and is
  # filtered out by the caller.
  defp trunc_or_nil(nil), do: nil
  defp trunc_or_nil(n) when is_integer(n) and n > 0, do: n
  defp trunc_or_nil(n) when is_float(n) and n > 0.0, do: trunc(n)
  defp trunc_or_nil(_), do: nil

  # Tarkov.dev returns attributes as `[%{"name" => ..., "value" => ...}]`.
  # We collapse to a flat map for storage; if duplicate names ever
  # appear the last wins, which is acceptable since this is rare
  # metadata used for display only.
  defp encode_attributes(nil), do: %{}

  defp encode_attributes(list) when is_list(list) do
    list
    |> Enum.reduce(%{}, fn
      %{"name" => name, "value" => value}, acc when is_binary(name) ->
        Map.put(acc, name, value)

      _, acc ->
        acc
    end)
  end

  defp encode_attributes(_), do: %{}
end
