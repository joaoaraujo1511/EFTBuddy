defmodule EftBuddy.Tasks.Sync do
  @moduledoc """
  Syncs tasks (quests), maps and their related objectives /
  requirements / rewards from the tarkov.dev JSON API (via
  `EftBuddy.TarkovApi`) into the local database.

  Unlike `EftBuddy.Items.Sync`, this module is **not** a
  `GenServer` and is **not** scheduled. Tasks
  change only on wipes / patches, so we trigger the sync manually
  from a remote IEx shell:

      EftBuddy.Tasks.Sync.run()

  The sync is idempotent: every run upserts the full snapshot
  returned by the API and replaces the dependent rows for every
  task in the response. Tasks / maps that disappear from the API
  are removed; the FK cascades take care of their children.

  Concurrency is guarded with `:global.set_lock/3`, so a second
  call while a sync is already running returns
  `{:error, :already_running}` instead of double-writing.
  """

  # Ticks twice as often as the other wipe-scale feeds. Quests are the only one
  # of them that changes between wipes: tarkov.dev re-tags them during events
  # (`"Easy Money - Part 1 [PVE ZONE]"` — see `EftBuddyWeb.TasksLive.Index`'s
  # `task_dedup_slugs/1`), new quests arrive with content patches, and /tasks is
  # the app's landing page.
  #
  # Last slot in the cycle, because `tasks.map_id` resolves against the maps
  # table. On the off-cycle tick there is no preceding maps run; that is fine,
  # since maps change on patches rather than daily and an unresolved `map_id` is
  # re-linked next run rather than persisting as a broken row.
  use EftBuddy.Sync.Scheduler,
    label: "TasksSync",
    interval: 12 * 60 * 60 * 1_000,
    stagger: 60 * 60 * 1_000,
    bootstrap: :ran,
    config_key: :tasks

  require Logger
  import Ecto.Query
  import EftBuddy.Sync.Helpers

  alias EftBuddy.Hideout.{Skill, Trader}
  alias EftBuddy.Items.Item
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter

  alias EftBuddy.Tasks.{
    ItemReward,
    Objective,
    ObjectiveMap,
    OfferUnlock,
    SkillReward,
    Task,
    TaskRequirement,
    TraderRequirement,
    TraderStandingReward,
    TraderUnlock,
    Unlock
  }

  # `EftBuddy.Maps.Map` (the game-location schema) is aliased as
  # `GameMap` so it doesn't shadow the stdlib `Map` module, which we
  # use heavily for the API-payload maps throughout this sync.
  #
  # The maps table is now owned by `EftBuddy.Maps.Sync` (it pulls the
  # full tarkov.dev `maps` query). We still upsert the bare
  # name/normalized_name here as a resilience fallback (so a task can
  # always resolve its `map_id` even if the Maps sync hasn't run), but
  # we deliberately no longer *delete* stale maps in `cleanup_stale/2` —
  # that lifecycle belongs to the Maps sync, and pruning here would
  # cascade-delete the rich map sub-entities (bosses, extracts, …).
  alias EftBuddy.Maps.Map, as: GameMap

  # ── Pipeline ───────────────────────────────────────────

  @impl EftBuddy.Sync.Scheduler
  # Returns `{:ok, counts}` or `{:error, reason}`. `run/0` (from
  # `EftBuddy.Sync.Scheduler`) wraps this in the cluster-wide lock.
  def do_run do
    results =
      Enum.map(EftBuddy.GameMode.all(), fn game_mode ->
        {game_mode, run_for_mode(game_mode)}
      end)

    errors = for {mode, {:error, reason}} <- results, do: {mode, reason}
    summary = for {mode, {:ok, counts}} <- results, into: %{}, do: {mode, counts}

    case errors do
      [] ->
        {:ok, summary}

      _ ->
        # Each mode is its own transaction, so a mode that succeeded is
        # already committed. We keep what committed and return a partial;
        # the per-mode error was already logged in `run_for_mode/1` and the
        # caller (Bootstrap / scheduler) logs the roll-up — no need to dump
        # the raw errors again here.
        {:error, {:partial, summary, errors}}
    end
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] Crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:crash, Exception.message(e)}}
  end

  # Run the full task pipeline for a single game mode, in its own
  # Reporter run (logs read `TasksSync:regular` / `TasksSync:pve`) and
  # its own transaction. The two modes are independent: PVE tasks are a
  # distinct quest graph keyed by `(external_id, game_mode)`, so the
  # snapshot, the id maps, the dependent-row replacement, and the stale
  # cleanup are all scoped to `game_mode`.
  defp run_for_mode(game_mode) do
    Reporter.with_run("TasksSync:#{game_mode}", fn ->
      case fetch_tasks(game_mode) do
        {:ok, raw_tasks} ->
          tasks = sanitize(raw_tasks)

          case upsert_all(tasks, game_mode) do
            {:ok, counts} ->
              {:ok, counts}

            {:error, _, reason, _} ->
              Logger.error(
                "[#{prefix()}] Multi failed (#{game_mode}): #{Reporter.describe_error(reason)}"
              )

              {:error, reason}

            {:error, reason} ->
              Logger.error(
                "[#{prefix()}] Error (#{game_mode}): #{Reporter.describe_error(reason)}"
              )

              {:error, reason}
          end

        {:error, reason} ->
          Logger.error(
            "[#{prefix()}] Fetch failed (#{game_mode}): #{Reporter.describe_error(reason)}"
          )

          {:error, reason}
      end
    end)
  end

  # ── Fetch ──────────────────────────────────────────────

  defp fetch_tasks(game_mode) do
    EftBuddy.TarkovApi.tasks(game_mode)
  end

  # ── Sanitize ───────────────────────────────────────────

  # Drop entries we can't FK-resolve later (missing required fields).
  #
  # Note: we deliberately do NOT try to filter out "daily" /
  # repeatable trader quests. `restartable: true` in the API does not
  # mean "daily" — it means "can be re-attempted after failing", a
  # property shared by ~16 main-line story quests (Punisher Part 6,
  # Drip-Out, Small Business Part 2, ...), so a `restartable`-based
  # heuristic would drop real story quests and break the
  # `task_unlocks` chain. The API exposes no reliable daily/recurring
  # field either, so rather than maintain a name-pattern list (drift
  # risk on every wipe) we store the full response and let dailies
  # render as ordinary tasks — the LOCKED / AVAILABLE chip makes them
  # easy to skip.
  defp sanitize(tasks) do
    Enum.filter(tasks, &has_required_fields?/1)
  end

  defp has_required_fields?(%{
         "id" => id,
         "name" => name,
         "normalizedName" => slug
       })
       when is_binary(id) and is_binary(name) and is_binary(slug),
       do: true

  defp has_required_fields?(_), do: false

  # ── Pipeline ───────────────────────────────────────────

  defp upsert_all(tasks, game_mode) do
    Ecto.Multi.new()
    # 1. Maps (FK target for tasks.map_id and task_objective_maps).
    |> Ecto.Multi.run(:upsert_maps, fn repo, _ -> upsert_maps(repo, tasks) end)
    |> Ecto.Multi.run(:map_id_map, fn repo, _ ->
      map_id_map_with_aliases(repo, tasks)
    end)
    # 2. Traders mentioned anywhere in this snapshot. The hideout sync
    #    seeds many traders already, but tasks reference traders that
    #    don't appear in the hideout (Fence, Lightkeeper, Ref). Upsert
    #    by `normalized_name` (matches existing Hideout.Sync behavior).
    |> Ecto.Multi.run(:upsert_traders, fn repo, _ -> upsert_traders(repo, tasks) end)
    |> Ecto.Multi.run(:trader_id_map, fn repo, _ ->
      {:ok, fetch_named_id_map(repo, Trader)}
    end)
    # 3. Skills referenced by skill rewards / objectives.
    |> Ecto.Multi.run(:upsert_skills, fn repo, _ -> upsert_skills(repo, tasks) end)
    |> Ecto.Multi.run(:skill_id_map, fn repo, _ ->
      {:ok, fetch_named_id_map(repo, Skill)}
    end)
    # 4. Item id map (FK target — items already populated by Items.Sync).
    |> Ecto.Multi.run(:item_id_map, fn repo, _ ->
      {:ok, fetch_external_id_map(repo, Item)}
    end)
    # 5. Tasks themselves. trader_id / map_id resolved via the maps above.
    |> Ecto.Multi.run(:upsert_tasks, fn repo, ctx -> upsert_tasks(repo, tasks, ctx, game_mode) end)
    |> Ecto.Multi.run(:task_id_map, fn repo, _ ->
      {:ok, fetch_task_id_map(repo, game_mode)}
    end)
    # 6. Replace all dependent rows for the tasks present in this snapshot.
    |> Ecto.Multi.run(:replace_objectives, fn repo, ctx ->
      replace_objectives(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_trader_reqs, fn repo, ctx ->
      replace_trader_requirements(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_task_reqs, fn repo, ctx ->
      replace_task_requirements(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_item_rewards, fn repo, ctx ->
      replace_item_rewards(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_trader_standing_rewards, fn repo, ctx ->
      replace_trader_standing_rewards(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_skill_rewards, fn repo, ctx ->
      replace_skill_rewards(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_trader_unlocks, fn repo, ctx ->
      replace_trader_unlocks(repo, tasks, ctx)
    end)
    |> Ecto.Multi.run(:replace_offer_unlocks, fn repo, ctx ->
      replace_offer_unlocks(repo, tasks, ctx)
    end)
    # 7. Compute the reverse index (task_unlocks).
    |> Ecto.Multi.run(:rebuild_unlocks, fn repo, _ -> rebuild_unlocks(repo) end)
    # 8. Drop tasks/maps that disappeared from the snapshot. FK
    #    cascades clean up their children.
    |> Ecto.Multi.run(:cleanup, fn repo, _ -> cleanup_stale(repo, tasks, game_mode) end)
    # 9. Final counts.
    |> Ecto.Multi.run(:counts, fn repo, _ ->
      {:ok,
       %{
         tasks: repo.aggregate(Task, :count, :id),
         objectives: repo.aggregate(Objective, :count, :id),
         maps: repo.aggregate(GameMap, :count, :id),
         unlocks: repo.aggregate(Unlock, :count, :id)
       }}
    end)
    |> Repo.transaction(timeout: 180_000)
    |> case do
      {:ok, %{counts: counts}} -> {:ok, counts}
      other -> other
    end
  end

  # ── Maps ───────────────────────────────────────────────

  # Collect maps from `task.map` and every objective's `maps[]`.
  defp upsert_maps(repo, tasks) do
    now = now_naive()

    rows =
      tasks
      |> collect_map_refs()
      |> Enum.uniq_by(& &1["id"])
      # Never seed the variant / event maps the Maps domain hides. Maps.Sync
      # runs first and folds them into their canonical row, so without this
      # guard a task referencing one would re-create a bare row that leaks onto
      # the Maps tab.
      #
      # Task *links* to those slugs are not lost, though — `objective_maps/2`
      # and `task_map_id/2` resolve them through `Maps.alias_slug/1` onto the
      # canonical map.
      |> Enum.reject(&(&1["normalizedName"] in EftBuddy.Maps.excluded_slugs()))
      |> Enum.map(fn m ->
        %{
          id: Ecto.UUID.generate(),
          external_id: m["id"],
          name: m["name"],
          normalized_name: m["normalizedName"],
          inserted_at: now,
          updated_at: now
        }
      end)

    # Seed-only: `EftBuddy.Maps.Sync` owns map attributes, so an existing row is
    # left untouched. Overwriting `name` here used to be harmless, but Ground
    # Zero's canonical row deliberately carries its 21+ sibling's name and
    # would be clobbered back to the base name on every task sync.
    bulk_upsert(repo, GameMap, rows,
      conflict_target: :external_id,
      on_conflict: :nothing
    )
  end

  # Every map reference in the snapshot: each task's primary map plus every
  # objective's `maps[]`.
  defp collect_map_refs(tasks) do
    tasks
    |> Enum.flat_map(fn task ->
      from_objectives =
        (task["objectives"] || [])
        |> Enum.flat_map(fn obj -> obj["maps"] || [] end)

      List.wrap(task["map"]) ++ from_objectives
    end)
    |> Enum.reject(&is_nil/1)
  end

  # `%{external_id => map_uuid}`, extended so references to hidden raid
  # variants resolve onto their canonical map instead of being dropped.
  #
  # `night-factory` and `ground-zero-21` are never seeded as map rows, so their
  # external ids are absent from the table. Every task link pointing at them
  # used to fall through `Enum.reject(&is_nil/1)` and disappear — 59 objective
  # references for night Factory and 37 for Ground Zero 21+, which made both
  # maps' quest badges understate reality.
  defp map_id_map_with_aliases(repo, tasks) do
    by_external = fetch_external_id_map(repo, GameMap)

    by_slug =
      from(m in GameMap, select: {m.normalized_name, m.id})
      |> repo.all()
      |> Map.new()

    aliased =
      tasks
      |> collect_map_refs()
      |> Enum.reduce(%{}, fn ref, acc ->
        id = ref["id"]
        slug = ref["normalizedName"]
        canonical = EftBuddy.Maps.alias_slug(slug)

        cond do
          is_nil(id) or Map.has_key?(by_external, id) -> acc
          canonical != slug -> maybe_put(acc, id, Map.get(by_slug, canonical))
          true -> acc
        end
      end)

    {:ok, Map.merge(by_external, aliased)}
  end

  # ── Traders ────────────────────────────────────────────

  defp upsert_traders(repo, tasks) do
    now = now_naive()

    rows =
      tasks
      |> Enum.flat_map(&collect_traders/1)
      |> Enum.reject(&is_nil/1)
      # Only the top-level `trader` selection carries `imageLink`; the
      # requirement / reward / objective trader refs don't. Sort the
      # image-bearing entries first so the subsequent `uniq_by` keeps
      # the portrait for every trader that gives a quest.
      |> Enum.sort_by(fn t -> if t["imageLink"], do: 0, else: 1 end)
      |> Enum.uniq_by(& &1["normalizedName"])
      |> Enum.map(fn t ->
        %{
          id: Ecto.UUID.generate(),
          name: t["name"] || t["normalizedName"],
          normalized_name: t["normalizedName"],
          image_link: t["imageLink"],
          inserted_at: now,
          updated_at: now
        }
      end)

    bulk_upsert(repo, Trader, rows,
      conflict_target: :normalized_name,
      replace: [:name, :image_link, :updated_at]
    )
  end

  # All trader references in a task snapshot — top-level, requirements,
  # rewards and reward sub-shapes. Used to seed the traders table.
  defp collect_traders(task) do
    primary = [task["trader"]]

    requirements =
      (task["traderRequirements"] || []) |> Enum.map(& &1["trader"])

    rewards =
      [task["startRewards"], task["finishRewards"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn r ->
        standings = (r["traderStanding"] || []) |> Enum.map(& &1["trader"])
        unlocks = r["traderUnlock"] || []
        offers = (r["offerUnlock"] || []) |> Enum.map(& &1["trader"])
        standings ++ unlocks ++ offers
      end)

    objective_traders =
      (task["objectives"] || [])
      |> Enum.flat_map(fn obj ->
        # Both `TaskObjectiveTraderLevel` and `…Standing` carry a trader.
        List.wrap(obj["trader"])
      end)

    primary ++ requirements ++ rewards ++ objective_traders
  end

  # ── Skills ─────────────────────────────────────────────

  defp upsert_skills(repo, tasks) do
    now = now_naive()

    rows =
      tasks
      |> Enum.flat_map(&collect_skill_names/1)
      |> Enum.reject(&is_nil/1)
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

    bulk_upsert(repo, Skill, rows,
      conflict_target: :normalized_name,
      replace: [:name, :updated_at]
    )
  end

  defp collect_skill_names(task) do
    reward_skills =
      [task["startRewards"], task["finishRewards"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn r -> r["skillLevelReward"] || [] end)
      |> Enum.map(& &1["name"])

    objective_skills =
      (task["objectives"] || [])
      |> Enum.flat_map(fn obj ->
        case obj["skillLevel"] do
          %{"name" => n} -> [n]
          _ -> []
        end
      end)

    reward_skills ++ objective_skills
  end

  # ── Tasks ──────────────────────────────────────────────

  defp upsert_tasks(repo, tasks, ctx, game_mode) do
    now = now_naive()
    %{trader_id_map: traders, map_id_map: maps} = ctx

    rows =
      Enum.map(tasks, fn t ->
        trader_id =
          case t["trader"] do
            %{"normalizedName" => slug} -> Map.get(traders, slug)
            _ -> nil
          end

        map_id =
          case t["map"] do
            %{"id" => id} -> Map.get(maps, id)
            _ -> nil
          end

        %{
          id: Ecto.UUID.generate(),
          external_id: t["id"],
          name: t["name"],
          normalized_name: t["normalizedName"],
          wiki_link: t["wikiLink"],
          task_image_link: t["taskImageLink"],
          faction_name: t["factionName"],
          experience: t["experience"],
          min_player_level: t["minPlayerLevel"],
          kappa_required: t["kappaRequired"] || false,
          lightkeeper_required: t["lightkeeperRequired"] || false,
          restartable: t["restartable"] || false,
          trader_id: trader_id,
          map_id: map_id,
          game_mode: game_mode,
          inserted_at: now,
          updated_at: now
        }
      end)

    replace = [
      :name,
      :normalized_name,
      :wiki_link,
      :task_image_link,
      :faction_name,
      :experience,
      :min_player_level,
      :kappa_required,
      :lightkeeper_required,
      :restartable,
      :trader_id,
      :map_id,
      :updated_at
    ]

    bulk_upsert(repo, Task, rows,
      conflict_target: [:external_id, :game_mode],
      replace: replace
    )
  end

  # ── Objectives ─────────────────────────────────────────

  # Objectives have rich subtype-specific fields. We promote the
  # common ones to columns and drop the rest into a `payload` jsonb,
  # keyed by the field name from the API. Items / questItem / trader
  # references are pre-resolved to local UUIDs so the UI doesn't have
  # to re-look them up.
  defp replace_objectives(repo, tasks, ctx) do
    %{task_id_map: tasks_map, item_id_map: items, trader_id_map: traders, map_id_map: maps} = ctx

    task_ids =
      tasks
      |> Enum.map(&Map.get(tasks_map, &1["id"]))
      |> Enum.reject(&is_nil/1)

    # Wipe existing objectives + their map joins for these tasks.
    # `task_objective_maps` cascades on objective delete.
    delete_in_chunks(repo, Objective, :task_id, task_ids)

    # Build objective rows + objective_map join rows in parallel.
    # We zip each task's API-order index onto its objectives via
    # `Enum.with_index/1` so the row carries a stable `:position`
    # column the renderer can sort on — `inserted_at` is unusable
    # here because every row built in this tight loop ends up with
    # the same second-precision timestamp, and the original `reduce
    # + [row | rows]` was even reversing the API order on top of
    # that. `flat_map` keeps the rows in document order in the
    # output list, which is also what `Repo.insert_all` writes them
    # in (no semantic dependency on physical row order, but
    # consistent with the API's intent).
    {objective_rows, objective_map_rows} =
      tasks
      |> Enum.flat_map(fn task ->
        case Map.get(tasks_map, task["id"]) do
          nil ->
            []

          task_id ->
            task
            |> Map.get("objectives", [])
            |> List.wrap()
            # Dedup objectives by their API id within the task. The
            # tarkov.dev API occasionally returns the same objective id
            # twice in one task's `objectives` list (observed on
            # "Fresh Stock" and "A Bitter Victory"). Both rows would
            # share (task_id, external_id) and violate the unique
            # index, crashing the whole sync. `uniq_by` keeps the first
            # occurrence, so the surviving row's `position` still
            # reflects the API's document order.
            |> Enum.uniq_by(fn obj -> obj["id"] end)
            |> Enum.with_index()
            |> Enum.map(fn {obj, position} -> {task_id, obj, position} end)
        end
      end)
      |> Enum.map_reduce([], fn {task_id, obj, position}, joins ->
        objective_id = Ecto.UUID.generate()

        row = %{
          id: objective_id,
          external_id: obj["id"],
          task_id: task_id,
          type: obj["type"],
          description: obj["description"],
          optional: obj["optional"] || false,
          payload: build_objective_payload(obj, items, traders),
          position: position,
          inserted_at: now_naive(),
          updated_at: now_naive()
        }

        join_rows =
          (obj["maps"] || [])
          |> Enum.map(&Map.get(maps, &1["id"]))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.map(fn map_id ->
            %{
              id: Ecto.UUID.generate(),
              objective_id: objective_id,
              map_id: map_id,
              inserted_at: now_naive(),
              updated_at: now_naive()
            }
          end)

        {row, join_rows ++ joins}
      end)

    inserted = bulk_insert(repo, Objective, objective_rows)
    _ = bulk_insert(repo, ObjectiveMap, objective_map_rows)

    {:ok, inserted}
  end

  # Subtype-specific fields → JSON. We resolve item / trader IDs to
  # local UUIDs at sync time so render-time code is just JSON access.
  defp build_objective_payload(obj, items, traders) do
    obj
    |> Map.take([
      "count",
      "foundInRaid",
      "targetNames",
      "shotType",
      "bodyParts",
      "exitStatus",
      "exitName",
      "playerLevel",
      "compareMethod",
      "value",
      "level",
      "status"
    ])
    |> maybe_put("items", resolve_item_refs(obj["items"], items))
    |> maybe_put("markerItem", resolve_item_ref(obj["markerItem"], items))
    |> maybe_put("questItem", resolve_item_ref(obj["questItem"], items))
    |> maybe_put("useAny", resolve_item_refs(obj["useAny"], items))
    |> maybe_put("item", resolve_item_ref(obj["item"], items))
    |> maybe_put("trader_id", resolve_trader_ref(obj["trader"], traders))
    |> maybe_put("skillLevel", obj["skillLevel"])
    |> maybe_put("task_external_id", get_in(obj, ["task", "id"]))
    # Keys the player needs to *complete* this objective (e.g. door
    # / extract gates). The API surfaces these as `[[Item]]` — a
    # list of alternative key-sets the player can use. For our
    # "Needed by quests" lookup we only care whether a given item
    # is mentioned anywhere, so we flatten and dedupe to a plain
    # list of local UUIDs and stash it on the payload as
    # `required_key_ids`. That mirrors how `items` is stored and
    # lets the per-item query do a single JSONB containment check.
    |> maybe_put("required_key_ids", resolve_required_keys(obj["requiredKeys"], items))
  end

  defp resolve_item_refs(nil, _), do: nil

  defp resolve_item_refs(refs, items) when is_list(refs) do
    refs
    |> Enum.map(&Map.get(items, &1["id"]))
    |> Enum.reject(&is_nil/1)
  end

  # `requiredKeys` comes back from the API as `[[Item]]` — a list
  # of *alternative* key-sets ("use any one of these key
  # combinations"). For surfacing keys on the per-item "Needed by
  # quests" panel we don't need to preserve the alternative
  # structure: we just want to know whether the item shows up at
  # all. Flatten one level, resolve to local UUIDs, dedupe.
  defp resolve_required_keys(nil, _), do: nil

  defp resolve_required_keys(groups, items) when is_list(groups) do
    groups
    |> List.flatten()
    |> Enum.map(fn
      %{"id" => id} -> Map.get(items, id)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_required_keys(_, _), do: nil

  defp resolve_item_ref(nil, _), do: nil
  defp resolve_item_ref(%{"id" => id}, items), do: Map.get(items, id)
  defp resolve_item_ref(_, _), do: nil

  defp resolve_trader_ref(nil, _), do: nil

  defp resolve_trader_ref(%{"normalizedName" => slug}, traders),
    do: Map.get(traders, slug)

  defp resolve_trader_ref(_, _), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Trader / Task requirements ─────────────────────────

  defp replace_trader_requirements(repo, tasks, ctx) do
    %{task_id_map: tasks_map, trader_id_map: traders} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, TraderRequirement, :task_id, task_ids)

    rows =
      tasks
      |> Enum.flat_map(fn t ->
        with task_id when not is_nil(task_id) <- Map.get(tasks_map, t["id"]),
             reqs when is_list(reqs) <- t["traderRequirements"] do
          Enum.flat_map(reqs, fn req ->
            case resolve_trader_ref(req["trader"], traders) do
              nil ->
                []

              trader_id ->
                [
                  %{
                    id: Ecto.UUID.generate(),
                    task_id: task_id,
                    trader_id: trader_id,
                    requirement_type: req["requirementType"],
                    compare_method: req["compareMethod"],
                    value: req["value"],
                    inserted_at: now_naive(),
                    updated_at: now_naive()
                  }
                ]
            end
          end)
        else
          _ -> []
        end
      end)

    {:ok, bulk_insert(repo, TraderRequirement, rows)}
  end

  defp replace_task_requirements(repo, tasks, ctx) do
    %{task_id_map: tasks_map} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, TaskRequirement, :task_id, task_ids)

    # Walk the snapshot once. We accumulate two things at the same
    # time: the rows we'd insert, and any prerequisite refs whose
    # target wasn't in the snapshot.
    #
    # Why we treat unknown refs as a hard failure: a silently-dropped
    # `taskRequirement` makes the dependent task look like it has *no*
    # prereqs, which makes it falsely AVAILABLE in the UI before the
    # player has done its real predecessor (e.g. "Small Business Part
    # 3" reading AVAILABLE while Part 1 is still LOCKED). Failing the
    # run is safer than corrupting the quest chain.
    {rows, missing} =
      Enum.reduce(tasks, {[], []}, fn t, {rows_acc, missing_acc} ->
        with task_id when not is_nil(task_id) <- Map.get(tasks_map, t["id"]),
             reqs when is_list(reqs) <- t["taskRequirements"] do
          Enum.reduce(reqs, {rows_acc, missing_acc}, fn req, {rows_a, miss_a} ->
            prereq_external = get_in(req, ["task", "id"])

            case Map.get(tasks_map, prereq_external) do
              nil ->
                {rows_a, [%{task: t["name"], missing_prereq_id: prereq_external} | miss_a]}

              prerequisite_task_id when prerequisite_task_id == task_id ->
                # Self-reference. Skip — these exist in the API
                # occasionally and aren't meaningful.
                {rows_a, miss_a}

              prerequisite_task_id ->
                row = %{
                  id: Ecto.UUID.generate(),
                  task_id: task_id,
                  prerequisite_task_id: prerequisite_task_id,
                  status: List.wrap(req["status"]),
                  inserted_at: now_naive(),
                  updated_at: now_naive()
                }

                {[row | rows_a], miss_a}
            end
          end)
        else
          _ -> {rows_acc, missing_acc}
        end
      end)

    case missing do
      [] ->
        {:ok, bulk_insert(repo, TaskRequirement, rows)}

      broken ->
        # Roll back the whole multi rather than corrupting the
        # quest chain. The most likely cause is `sanitize/1` (or a
        # future filter) dropping a task that's still referenced as
        # a prereq somewhere in the snapshot.
        {:error, {:missing_prereq_targets, Enum.reverse(broken)}}
    end
  end

  # ── Rewards ────────────────────────────────────────────

  defp replace_item_rewards(repo, tasks, ctx) do
    %{task_id_map: tasks_map, item_id_map: items} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, ItemReward, :task_id, task_ids)

    rows =
      flat_map_phases(tasks, tasks_map, fn task_id, phase, rewards ->
        (rewards["items"] || [])
        |> Enum.flat_map(fn entry ->
          case resolve_item_ref(entry["item"], items) do
            nil ->
              []

            item_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  task_id: task_id,
                  item_id: item_id,
                  quantity: entry["quantity"] || 1,
                  reward_phase: phase,
                  inserted_at: now_naive(),
                  updated_at: now_naive()
                }
              ]
          end
        end)
      end)
      # Same (task, item, phase) can appear twice in the API for split
      # rewards — collapse and sum quantities.
      |> Enum.group_by(&{&1.task_id, &1.item_id, &1.reward_phase})
      |> Enum.map(fn {_, group} ->
        total = group |> Enum.map(& &1.quantity) |> Enum.sum()
        group |> List.first() |> Map.put(:quantity, total)
      end)

    {:ok, bulk_insert(repo, ItemReward, rows)}
  end

  defp replace_trader_standing_rewards(repo, tasks, ctx) do
    %{task_id_map: tasks_map, trader_id_map: traders} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, TraderStandingReward, :task_id, task_ids)

    rows =
      flat_map_phases(tasks, tasks_map, fn task_id, phase, rewards ->
        (rewards["traderStanding"] || [])
        |> Enum.flat_map(fn entry ->
          case resolve_trader_ref(entry["trader"], traders) do
            nil ->
              []

            trader_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  task_id: task_id,
                  trader_id: trader_id,
                  standing: to_float(entry["standing"]) || 0.0,
                  reward_phase: phase,
                  inserted_at: now_naive(),
                  updated_at: now_naive()
                }
              ]
          end
        end)
      end)
      # Dedup the rare case of multiple rows for the same (task, trader, phase).
      |> Enum.uniq_by(&{&1.task_id, &1.trader_id, &1.reward_phase})

    {:ok, bulk_insert(repo, TraderStandingReward, rows)}
  end

  defp replace_skill_rewards(repo, tasks, ctx) do
    %{task_id_map: tasks_map, skill_id_map: skills} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, SkillReward, :task_id, task_ids)

    rows =
      flat_map_phases(tasks, tasks_map, fn task_id, phase, rewards ->
        (rewards["skillLevelReward"] || [])
        |> Enum.flat_map(fn entry ->
          case Map.get(skills, slugify(entry["name"] || "")) do
            nil ->
              []

            skill_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  task_id: task_id,
                  skill_id: skill_id,
                  level: to_float(entry["level"]) || 0.0,
                  reward_phase: phase,
                  inserted_at: now_naive(),
                  updated_at: now_naive()
                }
              ]
          end
        end)
      end)
      |> Enum.uniq_by(&{&1.task_id, &1.skill_id, &1.reward_phase})

    {:ok, bulk_insert(repo, SkillReward, rows)}
  end

  defp replace_trader_unlocks(repo, tasks, ctx) do
    %{task_id_map: tasks_map, trader_id_map: traders} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, TraderUnlock, :task_id, task_ids)

    rows =
      flat_map_phases(tasks, tasks_map, fn task_id, phase, rewards ->
        (rewards["traderUnlock"] || [])
        |> Enum.flat_map(fn entry ->
          case resolve_trader_ref(entry, traders) do
            nil ->
              []

            trader_id ->
              [
                %{
                  id: Ecto.UUID.generate(),
                  task_id: task_id,
                  trader_id: trader_id,
                  reward_phase: phase,
                  inserted_at: now_naive(),
                  updated_at: now_naive()
                }
              ]
          end
        end)
      end)
      |> Enum.uniq_by(&{&1.task_id, &1.trader_id, &1.reward_phase})

    {:ok, bulk_insert(repo, TraderUnlock, rows)}
  end

  defp replace_offer_unlocks(repo, tasks, ctx) do
    %{task_id_map: tasks_map, trader_id_map: traders, item_id_map: items} = ctx

    task_ids = task_uuids_from(tasks, tasks_map)
    delete_in_chunks(repo, OfferUnlock, :task_id, task_ids)

    rows =
      flat_map_phases(tasks, tasks_map, fn task_id, phase, rewards ->
        (rewards["offerUnlock"] || [])
        |> Enum.flat_map(fn entry ->
          trader_id = resolve_trader_ref(entry["trader"], traders)
          item_id = resolve_item_ref(entry["item"], items)
          level = entry["level"]

          if trader_id && item_id && is_integer(level) && level >= 1 do
            [
              %{
                id: Ecto.UUID.generate(),
                task_id: task_id,
                trader_id: trader_id,
                item_id: item_id,
                level: level,
                reward_phase: phase,
                inserted_at: now_naive(),
                updated_at: now_naive()
              }
            ]
          else
            []
          end
        end)
      end)
      |> Enum.uniq_by(&{&1.task_id, &1.trader_id, &1.item_id, &1.reward_phase})

    {:ok, bulk_insert(repo, OfferUnlock, rows)}
  end

  # Walk every (task, phase, rewards-map) triple in the snapshot.
  # `phase` is `:start` or `:finish`; `rewards` is the parsed JSON
  # object from `startRewards` / `finishRewards`.
  defp flat_map_phases(tasks, tasks_map, fun) do
    Enum.flat_map(tasks, fn t ->
      case Map.get(tasks_map, t["id"]) do
        nil ->
          []

        task_id ->
          Enum.flat_map([{:start, t["startRewards"]}, {:finish, t["finishRewards"]}], fn
            {_phase, nil} -> []
            {phase, rewards} -> fun.(task_id, phase, rewards)
          end)
      end
    end)
  end

  # ── Reverse-index ──────────────────────────────────────

  # Rebuild `task_unlocks` from scratch every run. Cheap (one delete +
  # one insert from a select). Filters to "complete" prerequisites,
  # which is what the chain UI actually wants to show.
  defp rebuild_unlocks(repo) do
    repo.delete_all(Unlock)

    now = now_naive()

    rows =
      from(r in TaskRequirement,
        where: fragment("? = ANY(?)", "complete", r.status),
        select: {r.prerequisite_task_id, r.task_id}
      )
      |> repo.all()
      |> Enum.uniq()
      |> Enum.map(fn {prereq, unlocked} ->
        %{
          id: Ecto.UUID.generate(),
          prerequisite_task_id: prereq,
          unlocked_task_id: unlocked,
          inserted_at: now,
          updated_at: now
        }
      end)

    {:ok, bulk_insert(repo, Unlock, rows)}
  end

  # ── Cleanup ────────────────────────────────────────────

  defp cleanup_stale(repo, tasks, game_mode) do
    valid_task_ids = Enum.map(tasks, & &1["id"])

    # Safety guard: a truncated-but-200 tasks snapshot would otherwise
    # delete every task missing from it and cascade-delete its
    # objectives / requirements / rewards / unlocks. Refuse the prune
    # when the snapshot is implausibly small relative to the table.
    # Scoped to this game mode so the count comparison is apples to
    # apples (the snapshot only covers one mode).
    current_tasks =
      repo.aggregate(from(t in Task, where: t.game_mode == ^game_mode), :count, :id)

    case cleanup_safe?(current_tasks, length(valid_task_ids)) do
      {:skip, reason} ->
        Logger.error(
          "[#{prefix()}] Refusing stale task cleanup (#{game_mode}): #{reason}. Keeping existing rows."
        )

        {:ok, %{tasks: 0}}

      :ok ->
        # Only ever delete tasks of THIS mode — the sibling mode's rows
        # share `external_id` values and must be left untouched.
        {task_count, _} =
          from(t in Task,
            where: t.game_mode == ^game_mode and t.external_id not in ^valid_task_ids
          )
          |> repo.delete_all()

        # NOTE: we intentionally do NOT prune stale `maps` here anymore.
        # The maps table is owned by `EftBuddy.Maps.Sync`, whose snapshot
        # is the authoritative set of maps (and is a superset of the maps
        # a task happens to reference). Deleting maps from the tasks
        # snapshot would cascade-delete the rich map sub-entities
        # (bosses, extracts, locks, …) and orphan `tasks.map_id`. Map
        # cleanup lives in `Maps.Sync.cleanup_stale/2`.
        {:ok, %{tasks: task_count}}
    end
  end

  # ── Helpers ────────────────────────────────────────────

  defp fetch_external_id_map(repo, schema) do
    from(x in schema, select: {x.external_id, x.id})
    |> repo.all()
    |> Map.new()
  end

  # Like `fetch_external_id_map/2` but scoped to a single game mode.
  # Tasks share `external_id` across modes, so the task id map MUST be
  # filtered by `game_mode` or the two modes' UUIDs would clobber each
  # other and dependent rows (objectives, prereqs, rewards) would
  # resolve to the wrong mode's task.
  defp fetch_task_id_map(repo, game_mode) do
    from(t in Task, where: t.game_mode == ^game_mode, select: {t.external_id, t.id})
    |> repo.all()
    |> Map.new()
  end

  defp fetch_named_id_map(repo, schema) do
    from(x in schema, select: {x.normalized_name, x.id})
    |> repo.all()
    |> Map.new()
  end

  defp task_uuids_from(tasks, tasks_map) do
    tasks
    |> Enum.map(&Map.get(tasks_map, &1["id"]))
    |> Enum.reject(&is_nil/1)
  end

  # Generic chunked bulk upsert that handles the empty-list case and
  # stays well below Postgres' 65535-parameter limit (2k rows × ~15
  # cols ≈ 30k params).
  defp bulk_upsert(_repo, _schema, [], _opts), do: {:ok, 0}

  defp bulk_upsert(repo, schema, rows, opts) do
    conflict_target = Keyword.fetch!(opts, :conflict_target)

    on_conflict =
      Keyword.get_lazy(opts, :on_conflict, fn ->
        {:replace, Keyword.fetch!(opts, :replace)}
      end)

    total =
      rows
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, _} =
          repo.insert_all(schema, chunk,
            on_conflict: on_conflict,
            conflict_target: conflict_target
          )

        acc + count
      end)

    {:ok, total}
  end

  defp bulk_insert(_repo, _schema, []), do: 0

  defp bulk_insert(repo, schema, rows) do
    rows
    |> Enum.chunk_every(2_000)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} = repo.insert_all(schema, chunk)
      acc + count
    end)
  end

  defp delete_in_chunks(_repo, _schema, _field, []), do: :ok

  defp delete_in_chunks(repo, schema, field, ids) do
    ids
    |> Enum.chunk_every(10_000)
    |> Enum.each(fn chunk ->
      from(r in schema, where: field(r, ^field) in ^chunk)
      |> repo.delete_all()
    end)
  end

  # Colorized module tag for this sync's own log lines (skipped:/error:/
  # crash:/etc.), so they match the coloring of the Reporter summary.
  # Mirrors the Bootstrap orchestrator's `prefix/0`.
end
