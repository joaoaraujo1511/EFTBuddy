defmodule EftBuddy.Hideout.Sync do
  @moduledoc """
  Syncs hideout stations, levels and their requirements (items /
  prerequisite stations / skills / traders) from the tarkov.dev JSON
  API (via `EftBuddy.TarkovApi`) into the local database.

  Like `EftBuddy.Tasks.Sync`, this module is **not** a `GenServer`
  and is **not** scheduled. Hideout data only changes on patches /
  wipes, so the sync runs once at boot via
  `EftBuddy.Sync.Bootstrap` and can be re-triggered manually from
  a remote IEx shell when needed:

      EftBuddy.Hideout.Sync.run()

  The sync is idempotent: every run upserts stations, levels and
  FK targets (skills, traders) and replaces all four requirement
  tables for the levels in the snapshot. Stations / levels that
  disappear from the API are removed; the FK cascade then deletes
  their children.

  Item requirements reference `EftBuddy.Items.Item` directly via
  FK, so the hideout cards always read fresh names / icons /
  prices from the items sync without having to duplicate those
  fields.

  Concurrency is guarded with `:global.set_lock/3`, so a second
  call while a sync is already running returns
  `{:error, :already_running}` instead of double-writing.
  """

  use GenServer

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Items.Item
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter

  alias EftBuddy.Hideout.{
    ItemRequirement,
    Skill,
    SkillRequirement,
    Station,
    StationLevel,
    StationLevelRequirement,
    Trader,
    TraderRequirement
  }

  @lock_id {__MODULE__, :running}

  # ── Schedule ───────────────────────────────────────────
  #
  # See `EftBuddy.Ammo.Sync`'s schedule section for the full reasoning; the
  # modules are deliberately identical here apart from the slot.

  @default_interval 24 * 60 * 60 * 1_000

  # Slot in the daily cycle: maps +20 → hideout +30 → ammo +40 → armor +50 →
  # tasks +60, which keeps Bootstrap's FK ordering inside a cycle and avoids the
  # wiki chain's +0 / +1 min / +8 min.
  @stagger 30 * 60 * 1_000

  # A FULL INTERVAL from `:bootstrap_complete`, not zero: Bootstrap runs this
  # sync itself as part of the cold start, so it has already happened by the
  # time the cast arrives. (The wiki scrapers use 0 because Bootstrap only
  # *releases* them.)
  @bootstrap_offset @default_interval + @stagger

  # Short fallback for when the bootstrap signal never arrives — in that case
  # this sync has NOT run and the table may be empty.
  @fallback_delay 15 * 60 * 1_000 + @stagger

  @doc false
  # Public so `EftBuddy.Sync.Freshness` can assert its staleness budget covers
  # this cadence rather than trusting a comment to keep the two in step.
  def interval_ms, do: @default_interval

  @doc false
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Logger.info(
          "[#{prefix()}] Another node already runs the hideout sync; staying idle here."
        )

        :ignore
    end
  end

  @doc "Trigger a sync asynchronously (e.g. from IEx)."
  def sync_now, do: GenServer.cast({:global, __MODULE__}, :sync_now)

  # ── Server ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    first = Keyword.get(opts, :first_run_delay, @fallback_delay)
    timer = Process.send_after(self(), :sync, first + jitter(first))
    {:ok, %{interval: interval, timer: timer}}
  end

  @impl true
  def handle_info(:sync, %{interval: interval} = state) do
    safe_run()
    timer = Process.send_after(self(), :sync, interval + jitter(interval))
    {:noreply, %{state | timer: timer}}
  end

  @impl true
  def handle_cast(:bootstrap_complete, state) do
    {:noreply, arm_first_run(state, @bootstrap_offset)}
  end

  def handle_cast(:sync_now, state) do
    safe_run()
    {:noreply, state}
  end

  defp arm_first_run(state, offset) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :sync, offset + jitter(offset))
    %{state | timer: timer}
  end

  defp safe_run do
    case run() do
      {:ok, summary} ->
        Logger.info("[#{prefix()}] done: #{inspect(summary)}")
        {:ok, summary}

      {:error, :already_running} ->
        Logger.info("[#{prefix()}] skipped: another hideout sync is already running")
        {:error, :already_running}

      {:error, reason} ->
        Logger.warning("[#{prefix()}] run ended early: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:crash, Exception.message(e)}}
  end

  # ±10%, so several nodes (or several restarts) never align on one instant.
  defp jitter(ms) when is_integer(ms) and ms > 0, do: :rand.uniform(div(ms, 10) + 1)
  defp jitter(_), do: 0

  # ── Public API ─────────────────────────────────────────

  @doc """
  Run a full sync of hideout stations / levels / requirements.
  Synchronous: blocks until done.

  Returns `{:ok, %{stations: count, levels: count}}` on success or
  `{:error, reason}`. Returns `{:error, :already_running}` if
  another sync is in progress on any node in the cluster.

  Invoked once at boot by `EftBuddy.Sync.Bootstrap` and otherwise
  only when a dev calls it directly from IEx. There is no
  recurring schedule — hideout data only changes on patches /
  wipes, so a manual re-run on demand is sufficient.
  """
  def run do
    case acquire_lock() do
      true ->
        try do
          do_run()
        after
          release_lock()
        end

      false ->
        Logger.warning("[#{prefix()}] Skipped: another sync is already running.")
        {:error, :already_running}
    end
  end

  # `:global.set_lock/3` is cluster-wide and re-entrant per-pid; we
  # only ever hold it for the duration of a single `run/0` call.
  # Same shape as `EftBuddy.Tasks.Sync`.
  defp acquire_lock do
    :global.set_lock(@lock_id, [node() | Node.list()], 0)
  end

  defp release_lock do
    :global.del_lock(@lock_id, [node() | Node.list()])
  end

  # ── Pipeline ───────────────────────────────────────────

  defp do_run do
    Reporter.with_run("HideoutSync", fn ->
      case fetch_stations() do
        {:ok, raw_stations} ->
          stations = sanitize_stations(raw_stations)

          case upsert_all(stations) do
            {:ok, %{stations_count: s, levels_count: l}} ->
              {:ok, %{stations: s, levels: l}}

            {:error, _, reason, _} ->
              Logger.error("[#{prefix()}] Multi failed: #{Reporter.describe_error(reason)}")
              {:error, reason}

            {:error, reason} ->
              Logger.error("[#{prefix()}] Error: #{Reporter.describe_error(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.error("[#{prefix()}] Fetch failed: #{Reporter.describe_error(reason)}")
          {:error, reason}
      end
    end)
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] Crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:crash, Exception.message(e)}}
  end

  defp fetch_stations do
    EftBuddy.TarkovApi.hideout_stations()
  end

  # Drop entries that are missing the bits we depend on so later code
  # never sees `nil["..."]`.
  defp sanitize_stations(stations) do
    stations
    |> Enum.filter(fn
      %{"name" => name, "normalizedName" => slug, "levels" => levels}
      when is_binary(name) and is_binary(slug) and is_list(levels) ->
        true

      _ ->
        false
    end)
    |> Enum.map(fn station ->
      Map.update!(station, "levels", &sanitize_levels/1)
    end)
  end

  defp sanitize_levels(levels) do
    levels
    |> Enum.filter(fn
      %{"level" => level} when is_integer(level) and level >= 1 -> true
      _ -> false
    end)
    |> Enum.map(fn level ->
      level
      |> Map.update("itemRequirements", [], &sanitize_item_reqs/1)
      |> Map.update("stationLevelRequirements", [], &sanitize_station_reqs/1)
      |> Map.update("skillRequirements", [], &sanitize_skill_reqs/1)
      |> Map.update("traderRequirements", [], &sanitize_trader_reqs/1)
    end)
  end

  defp sanitize_item_reqs(reqs) when is_list(reqs) do
    Enum.filter(reqs, fn
      %{"item" => %{"id" => id}, "quantity" => q}
      when is_binary(id) and is_integer(q) and q > 0 ->
        true

      _ ->
        false
    end)
  end

  defp sanitize_item_reqs(_), do: []

  defp sanitize_station_reqs(reqs) when is_list(reqs) do
    Enum.filter(reqs, fn
      %{"level" => l, "station" => %{"normalizedName" => slug, "name" => name}}
      when is_integer(l) and l >= 1 and is_binary(slug) and is_binary(name) ->
        true

      _ ->
        false
    end)
  end

  defp sanitize_station_reqs(_), do: []

  defp sanitize_skill_reqs(reqs) when is_list(reqs) do
    Enum.filter(reqs, fn
      %{"level" => l, "name" => name}
      when is_integer(l) and l >= 1 and is_binary(name) ->
        true

      _ ->
        false
    end)
  end

  defp sanitize_skill_reqs(_), do: []

  defp sanitize_trader_reqs(reqs) when is_list(reqs) do
    Enum.filter(reqs, fn
      %{"level" => l, "trader" => %{"normalizedName" => slug, "name" => name}}
      when is_integer(l) and l >= 1 and is_binary(slug) and is_binary(name) ->
        true

      _ ->
        false
    end)
  end

  defp sanitize_trader_reqs(_), do: []

  # ── Transaction ────────────────────────────────────────

  defp upsert_all(stations) do
    Ecto.Multi.new()
    # 1. Stations — FK target for levels and station-level requirements.
    |> Ecto.Multi.run(:upsert_stations, &upsert_stations(&1, stations, &2))
    |> Ecto.Multi.run(:station_map, fn repo, _ ->
      {:ok, fetch_station_map(repo)}
    end)
    # 2. Skills / traders — derived from level requirements; FK targets for the
    #    requirement tables. Done before levels so they're ready for the
    #    requirement inserts at step 5.
    |> Ecto.Multi.run(:upsert_skills, &upsert_skills(&1, stations, &2))
    |> Ecto.Multi.run(:skill_map, fn repo, _ ->
      {:ok, fetch_named_map(repo, Skill)}
    end)
    |> Ecto.Multi.run(:upsert_traders, &upsert_traders(&1, stations, &2))
    |> Ecto.Multi.run(:trader_map, fn repo, _ ->
      {:ok, fetch_named_map(repo, Trader)}
    end)
    # 3. Levels — bulk upsert keyed on (station_id, level).
    |> Ecto.Multi.run(:upsert_levels, fn repo, %{station_map: station_map} ->
      upsert_levels(repo, stations, station_map)
    end)
    |> Ecto.Multi.run(:level_map, fn repo, %{station_map: station_map} ->
      {:ok, fetch_level_map(repo, station_map)}
    end)
    |> Ecto.Multi.run(:item_map, fn repo, _ ->
      {:ok, fetch_item_map(repo)}
    end)
    # 4. Replace requirement rows for every level present in this snapshot.
    |> Ecto.Multi.run(:replace_item_reqs, fn repo, %{level_map: level_map, item_map: item_map} ->
      replace_item_requirements(repo, stations, level_map, item_map)
    end)
    |> Ecto.Multi.run(:replace_station_reqs, fn repo,
                                                %{
                                                  level_map: level_map,
                                                  station_map: station_map
                                                } ->
      replace_station_level_requirements(repo, stations, level_map, station_map)
    end)
    |> Ecto.Multi.run(:replace_skill_reqs, fn repo,
                                              %{level_map: level_map, skill_map: skill_map} ->
      replace_skill_requirements(repo, stations, level_map, skill_map)
    end)
    |> Ecto.Multi.run(:replace_trader_reqs, fn repo,
                                               %{
                                                 level_map: level_map,
                                                 trader_map: trader_map
                                               } ->
      replace_trader_requirements(repo, stations, level_map, trader_map)
    end)
    # 5. Drop stations/levels that disappeared from the API. FK cascades
    #    take care of their requirement rows.
    |> Ecto.Multi.run(:cleanup, fn repo, _ ->
      cleanup_stale(repo, stations)
    end)
    # 6. Final counts for logging.
    |> Ecto.Multi.run(:final_counts, fn repo, _ ->
      {:ok,
       %{
         stations_count: repo.aggregate(Station, :count, :id),
         levels_count: repo.aggregate(StationLevel, :count, :id)
       }}
    end)
    |> Repo.transaction(timeout: 120_000)
    |> case do
      {:ok, %{final_counts: counts}} -> {:ok, counts}
      other -> other
    end
  end

  # ── Stations ───────────────────────────────────────────

  defp upsert_stations(repo, stations, _changes) do
    now = now_naive()

    rows =
      stations
      |> Enum.uniq_by(& &1["normalizedName"])
      |> Enum.map(fn s ->
        %{
          id: Ecto.UUID.generate(),
          name: s["name"],
          normalized_name: s["normalizedName"],
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          repo.insert_all(Station, rows,
            on_conflict: {:replace, [:name, :updated_at]},
            conflict_target: :normalized_name
          )

        {:ok, count}
    end
  end

  defp fetch_station_map(repo) do
    from(s in Station, select: {s.normalized_name, s.id})
    |> repo.all()
    |> Map.new()
  end

  # ── Skills ─────────────────────────────────────────────

  defp upsert_skills(repo, stations, _changes) do
    now = now_naive()

    rows =
      stations
      |> Enum.flat_map(fn s -> s["levels"] end)
      |> Enum.flat_map(fn l -> l["skillRequirements"] || [] end)
      |> Enum.map(& &1["name"])
      |> Enum.uniq()
      |> Enum.map(fn name ->
        %{
          id: Ecto.UUID.generate(),
          name: name,
          normalized_name: slugify(name),
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          repo.insert_all(Skill, rows,
            on_conflict: {:replace, [:name, :updated_at]},
            conflict_target: :normalized_name
          )

        {:ok, count}
    end
  end

  # ── Traders ────────────────────────────────────────────

  defp upsert_traders(repo, stations, _changes) do
    now = now_naive()

    rows =
      stations
      |> Enum.flat_map(fn s -> s["levels"] end)
      |> Enum.flat_map(fn l -> l["traderRequirements"] || [] end)
      |> Enum.map(& &1["trader"])
      |> Enum.uniq_by(& &1["normalizedName"])
      |> Enum.map(fn t ->
        %{
          id: Ecto.UUID.generate(),
          name: t["name"],
          normalized_name: t["normalizedName"],
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          repo.insert_all(Trader, rows,
            on_conflict: {:replace, [:name, :updated_at]},
            conflict_target: :normalized_name
          )

        {:ok, count}
    end
  end

  # Generic fetcher for {normalized_name, id} maps. Works for any
  # schema that has a `:normalized_name` field.
  defp fetch_named_map(repo, schema) do
    from(x in schema, select: {x.normalized_name, x.id})
    |> repo.all()
    |> Map.new()
  end

  # ── Levels ─────────────────────────────────────────────

  defp upsert_levels(repo, stations, station_map) do
    now = now_naive()

    rows =
      stations
      |> Enum.flat_map(fn s ->
        case Map.get(station_map, s["normalizedName"]) do
          nil ->
            []

          station_id ->
            Enum.map(s["levels"], fn level ->
              %{
                id: Ecto.UUID.generate(),
                level: level["level"],
                station_id: station_id,
                inserted_at: now,
                updated_at: now
              }
            end)
        end
      end)

    case rows do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          repo.insert_all(StationLevel, rows,
            on_conflict: {:replace, [:updated_at]},
            conflict_target: [:station_id, :level]
          )

        {:ok, count}
    end
  end

  # Map keyed on `{station_slug, level}` → level UUID, so requirement
  # inserts can resolve their FK without an extra round-trip per row.
  defp fetch_level_map(repo, station_map) do
    inverse_station_map = Map.new(station_map, fn {slug, id} -> {id, slug} end)

    from(l in StationLevel, select: {l.station_id, l.level, l.id})
    |> repo.all()
    |> Enum.reduce(%{}, fn {station_id, level, id}, acc ->
      case Map.get(inverse_station_map, station_id) do
        nil -> acc
        slug -> Map.put(acc, {slug, level}, id)
      end
    end)
  end

  defp fetch_item_map(repo) do
    from(i in Item, select: {i.external_id, i.id})
    |> repo.all()
    |> Map.new()
  end

  # ── Requirements (replace strategy) ────────────────────

  # Replace strategy: for every level present in the snapshot, delete
  # its existing requirement rows in this table, then bulk-insert the
  # new ones. Atomic within the transaction. "Present in the snapshot" is
  # load-bearing and enforced by `replace_level_children/5` — see there.

  defp replace_item_requirements(repo, stations, level_map, item_map) do
    rows =
      flat_map_levels(stations, level_map, fn level_id, level ->
        Enum.flat_map(level["itemRequirements"] || [], fn req ->
          case Map.get(item_map, req["item"]["id"]) do
            nil ->
              # Item from the hideout API isn't in the local items table
              # yet (the items sync runs more often, so this should heal
              # itself on the next run). Skip rather than fail.
              # Counted via Reporter so we get one summary number per
              # run instead of N lines per missing-item.
              Reporter.silent_warn(
                "[#{prefix()}] Skipping item requirement: external_id=#{inspect(req["item"]["id"])} not found in items"
              )

              []

            item_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  level_id: level_id,
                  item_id: item_id,
                  quantity: req["quantity"]
                }
              ]
          end
        end)
      end)

    replace_level_children(repo, ItemRequirement, stations, level_map, rows)
  end

  defp replace_station_level_requirements(repo, stations, level_map, station_map) do
    rows =
      flat_map_levels(stations, level_map, fn level_id, level ->
        Enum.flat_map(level["stationLevelRequirements"] || [], fn req ->
          case Map.get(station_map, req["station"]["normalizedName"]) do
            nil ->
              []

            required_station_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  level_id: level_id,
                  required_station_id: required_station_id,
                  required_level: req["level"]
                }
              ]
          end
        end)
      end)

    replace_level_children(repo, StationLevelRequirement, stations, level_map, rows)
  end

  defp replace_skill_requirements(repo, stations, level_map, skill_map) do
    rows =
      flat_map_levels(stations, level_map, fn level_id, level ->
        Enum.flat_map(level["skillRequirements"] || [], fn req ->
          case Map.get(skill_map, slugify(req["name"])) do
            nil ->
              []

            skill_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  level_id: level_id,
                  skill_id: skill_id,
                  required_level: req["level"]
                }
              ]
          end
        end)
      end)

    replace_level_children(repo, SkillRequirement, stations, level_map, rows)
  end

  defp replace_trader_requirements(repo, stations, level_map, trader_map) do
    rows =
      flat_map_levels(stations, level_map, fn level_id, level ->
        Enum.flat_map(level["traderRequirements"] || [], fn req ->
          case Map.get(trader_map, req["trader"]["normalizedName"]) do
            nil ->
              []

            trader_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  level_id: level_id,
                  trader_id: trader_id,
                  required_level: req["level"]
                }
              ]
          end
        end)
      end)

    replace_level_children(repo, TraderRequirement, stations, level_map, rows)
  end

  # Walks every level in the snapshot, calls `fun.(level_id, level_map)`,
  # and flat-collects the results. Levels whose UUID isn't in
  # `level_map` (shouldn't happen since we just inserted them) are
  # silently skipped.
  defp flat_map_levels(stations, level_map, fun) do
    stations
    |> Enum.flat_map(fn s ->
      Enum.flat_map(s["levels"], fn level ->
        case Map.get(level_map, {s["normalizedName"], level["level"]}) do
          nil -> []
          level_id -> fun.(level_id, level)
        end
      end)
    end)
  end

  @doc false
  # The DB ids of only those station levels the current upstream snapshot carried.
  #
  # `level_map` comes from `fetch_level_map/2`, which reads the ENTIRE
  # `station_levels` table (its station filter is itself built from
  # `fetch_station_map/1`, i.e. the entire stations table). Intersecting it with the
  # snapshot is what keeps `replace_level_children/5`'s delete in bounds.
  #
  # Public only so it can be unit-tested; treat it as private.
  def snapshot_level_ids(stations, level_map) do
    pairs =
      Enum.flat_map(stations, fn s ->
        Enum.map(s["levels"] || [], fn l -> {s["normalizedName"], l["level"]} end)
      end)

    level_map
    |> Map.take(pairs)
    |> Map.values()
    |> Enum.uniq()
  end

  @doc false
  # Replace strategy for one requirement table: delete the rows belonging to the
  # levels THIS SNAPSHOT carried, then bulk insert the fresh set. Chunked to stay
  # under Postgres' 65535-parameter limit. Atomic within the caller's transaction.
  #
  # It derives its own scope from `stations` + `level_map` rather than accepting a
  # ready-made id list, for the same reason as
  # `EftBuddy.Items.Sync.replace_children/5`: passing `Map.values(level_map)` — the
  # whole table — deleted the requirements of every level in the database, while
  # `cleanup_stale/2` then refused to prune the stations a truncated snapshot had
  # omitted. The visible result is hideout stations with zero item, skill, trader
  # and prerequisite requirements, rendered as fact. Making the wrong argument
  # inexpressible is cheaper than documenting a contract on four call sites.
  #
  # Public only so it can be unit-tested; treat it as private.
  def replace_level_children(repo, schema, stations, level_map, rows)

  # An empty row set means this run resolved NOTHING for this table, which is not
  # the same as "there is nothing". It is what `Bootstrap` produces when the items
  # sync failed and the hideout sync ran anyway: every item requirement falls
  # through the "not found in items" skip below, and deleting on that basis empties
  # the table with nothing to reinsert. Keep what we have instead.
  #
  # The cost of the clause is that a requirement table which legitimately becomes
  # empty across the board keeps stale rows until it has at least one again. That
  # trade is deliberate and matches `Items.Sync`.
  def replace_level_children(_repo, _schema, _stations, _level_map, []), do: {:ok, 0}

  def replace_level_children(repo, schema, stations, level_map, rows) do
    now = now_naive()
    rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    stations
    |> snapshot_level_ids(level_map)
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      from(r in schema, where: r.level_id in ^chunk)
      |> repo.delete_all()
    end)

    inserted =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} = repo.insert_all(schema, chunk)
        acc + count
      end)

    {:ok, inserted}
  end

  # ── Cleanup ────────────────────────────────────────────

  # Stations absent from the snapshot — and (via cascade) their
  # levels and requirement rows — are removed. We also prune
  # individual levels that vanished from a station that's still
  # present (e.g. if BSG ever trims a level off a station).
  # Skills and traders are intentionally left in place because
  # other features may reference them.
  defp cleanup_stale(repo, stations) do
    valid_slugs = Enum.map(stations, & &1["normalizedName"])

    # Safety guard: refuse to prune stations (and cascade their levels +
    # requirement rows) when the snapshot is implausibly small relative
    # to the table — a truncated-but-200 upstream response.
    current_stations = repo.aggregate(Station, :count, :id)

    case cleanup_safe?(current_stations, length(valid_slugs)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale station cleanup: #{reason}. Keeping existing rows."
        )

        {:ok, %{stations: 0, levels: 0}}

      :ok ->
        do_cleanup_stale(repo, stations, valid_slugs)
    end
  end

  defp do_cleanup_stale(repo, stations, valid_slugs) do
    {station_count, _} =
      from(s in Station, where: s.normalized_name not in ^valid_slugs)
      |> repo.delete_all()

    # For surviving stations, prune levels not in the snapshot.
    valid_pairs =
      stations
      |> Enum.flat_map(fn s ->
        Enum.map(s["levels"], fn l -> {s["normalizedName"], l["level"]} end)
      end)

    level_count =
      from(l in StationLevel,
        join: s in assoc(l, :station),
        select: {l.id, s.normalized_name, l.level}
      )
      |> repo.all()
      |> Enum.filter(fn {_id, slug, level} -> {slug, level} not in valid_pairs end)
      |> Enum.map(fn {id, _, _} -> id end)
      |> case do
        [] ->
          0

        ids ->
          {count, _} =
            from(l in StationLevel, where: l.id in ^ids)
            |> repo.delete_all()

          count
      end

    {:ok, %{stations: station_count, levels: level_count}}
  end

  # Colorized module tag for this sync's own log lines (skipped:/error:/
  # crash:/etc.), so they match the coloring of the Reporter summary.
  # Mirrors the Bootstrap orchestrator's `prefix/0`.
  defp prefix, do: Reporter.colorize_label("HideoutSync")
end
