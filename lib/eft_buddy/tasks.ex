defmodule EftBuddy.Tasks do
  @moduledoc """
  The Tasks context. Reads tasks, objectives, requirements and
  rewards for the LiveView to render the tasks list / detail pages.

  Data is populated by `EftBuddy.Tasks.Sync` — manually triggered
  from IEx (no scheduler). See that module's docs for invocation.
  """

  import Ecto.Query

  alias EftBuddy.Items.Item
  alias EftBuddy.Cache
  alias EftBuddy.Repo

  alias EftBuddy.Hideout.Trader

  alias EftBuddy.Tasks.{
    Task,
    TaskRequirement
  }

  @default_preloads [
    :trader,
    :map,
    :objectives,
    :trader_requirements,
    :task_requirements,
    :item_rewards,
    :trader_standing_rewards,
    :skill_rewards,
    :trader_unlocks,
    :offer_unlocks
  ]

  # ── Reads ──────────────────────────────────────────────

  # Same shape as @default_preloads but with the second-level
  # joins materialized (item_rewards.item, trader_standing.trader,
  # etc.) so the detail panel can render names and icons without
  # spawning N+1 queries during HEEx rendering.
  @detail_preloads [
    :trader,
    :map,
    :objectives,
    [trader_requirements: :trader],
    [task_requirements: :prerequisite_task],
    [item_rewards: :item],
    [trader_standing_rewards: :trader],
    [skill_rewards: :skill],
    [trader_unlocks: :trader],
    [offer_unlocks: [:trader, :item]]
  ]

  @doc """
  Returns a single task with every association needed to render the
  expanded detail panel: trader, objectives (ordered), all reward
  flavors, trader/offer unlocks, prerequisite tasks. Returns nil
  if no task with the given id exists.

  Used by the Tasks LiveView's lazy-on-expand cache, so we pay this
  query cost only when a row is actually opened, not at mount.
  """
  def get_task_details(task_id) when is_binary(task_id) do
    from(t in Task, where: t.id == ^task_id)
    |> preload(^@detail_preloads)
    |> Repo.one()
  end

  def get_task_details(_), do: nil

  @doc """
  Returns the items referenced by any of the task's objectives —
  items to find / hand over, marker items, "use any of these"
  items, required keys, AND any quest-exclusive items (Golden
  Zibbo lighter, Cult medallion, …). Quest items live in the same
  `items` table as regular items (with `is_quest_item: true`).

  Each entry is a map carrying display metadata the panel needs:

      %{
        item: %Item{},
        found_in_raid: boolean(),   # turn-in must be Found-in-Raid
        count: pos_integer() | nil  # how many are required
      }

  `found_in_raid` reflects the API's per-objective `foundInRaid`
  flag (only `TaskObjectiveItem` turn-ins carry it). When the same
  item is referenced by several objectives we OR the flags (a FiR
  requirement anywhere wins) and take the max count. Keys, marker
  items, "use any" items and build targets have no FiR / count
  semantics, so they come through as `found_in_raid: false,
  count: nil`.

  Resilient to the transition between the old "questItem stored
  as a raw API map" payload shape and the new "questItem stored
  as a local UUID" shape: we collect both UUIDs (binaries) and
  external_id refs (`%{"id" => "..."}` maps) and feed both into
  a single `WHERE id IN ... OR external_id IN ...` query. Old
  payloads still resolve until they get re-synced.
  """
  def required_items_for(%{objectives: objs}) when is_list(objs) do
    meta_by_ref =
      objs
      |> Enum.flat_map(&objective_item_refs_with_meta/1)
      |> Enum.reduce(%{}, fn {ref, meta}, acc ->
        Map.update(acc, ref, meta, &merge_item_meta(&1, meta))
      end)

    {uuids, external_ids} = meta_by_ref |> Map.keys() |> split_refs()

    case {uuids, external_ids} do
      {[], []} ->
        []

      _ ->
        from(i in Item,
          where: i.id in ^uuids or i.external_id in ^external_ids
        )
        |> Repo.all()
        |> Enum.map(fn item ->
          meta = meta_for_item(meta_by_ref, item)

          %{item: item, found_in_raid: meta.found_in_raid, count: meta.count}
        end)
        # Stable display order: alphabetical by name, since the
        # API doesn't carry a "primary item first" hint and we'd
        # otherwise get whatever Postgres returns.
        |> Enum.sort_by(& &1.item.name)
    end
  end

  def required_items_for(_), do: []

  # Walk every per-objective payload field that can carry an item
  # ref, pairing each ref with the display metadata for that
  # objective. Returns a flat list of `{ref, %{found_in_raid:,
  # count:}}` tuples, ref being either:
  #   - `<binary uuid>`           — already resolved by Tasks.Sync
  #   - `%{"id" => external_id}`  — raw API map, not yet re-resolved
  #
  # Only `TaskObjectiveItem` turn-ins (`payload.items`) carry the
  # `foundInRaid` flag and a meaningful `count`; quest items carry
  # a count but no FiR flag (the API omits it for that subtype);
  # everything else (build target, marker, "use any", keys) has
  # neither.
  defp objective_item_refs_with_meta(%{payload: payload}) when is_map(payload) do
    fir? = payload["foundInRaid"] == true
    count = normalize_count(payload["count"])

    turn_in =
      payload["items"]
      |> List.wrap()
      |> Enum.map(&{&1, %{found_in_raid: fir?, count: count}})

    quest =
      payload["questItem"]
      |> List.wrap()
      |> Enum.map(&{&1, %{found_in_raid: false, count: count}})

    others =
      (List.wrap(payload["item"]) ++
         List.wrap(payload["markerItem"]) ++
         List.wrap(payload["useAny"]) ++
         List.wrap(payload["required_key_ids"]))
      |> Enum.map(&{&1, %{found_in_raid: false, count: nil}})

    turn_in ++ quest ++ others
  end

  defp objective_item_refs_with_meta(_), do: []

  # Combine two metadata maps for the same item: a FiR requirement
  # anywhere makes the item FiR; the count is the larger of the two
  # (nil-safe).
  defp merge_item_meta(a, b) do
    %{
      found_in_raid: a.found_in_raid or b.found_in_raid,
      count: max_count(a.count, b.count)
    }
  end

  defp max_count(nil, b), do: b
  defp max_count(a, nil), do: a
  defp max_count(a, b), do: max(a, b)

  defp normalize_count(n) when is_integer(n) and n > 0, do: n
  defp normalize_count(_), do: nil

  # Resolve the metadata for a fetched `%Item{}` by checking both
  # possible ref-key shapes (UUID and legacy external_id map) and
  # merging if, during the transitional payload window, the item
  # was referenced under both.
  defp meta_for_item(meta_by_ref, item) do
    by_uuid = Map.get(meta_by_ref, item.id)
    by_ext = Map.get(meta_by_ref, %{"id" => item.external_id})

    case {by_uuid, by_ext} do
      {nil, nil} -> %{found_in_raid: false, count: nil}
      {m, nil} -> m
      {nil, m} -> m
      {a, b} -> merge_item_meta(a, b)
    end
  end

  defp split_refs(refs) do
    Enum.reduce(refs, {[], []}, fn
      ref, {uuids, ext_ids} when is_binary(ref) ->
        {[ref | uuids], ext_ids}

      %{"id" => ext_id}, {uuids, ext_ids} when is_binary(ext_id) ->
        {uuids, [ext_id | ext_ids]}

      _, acc ->
        acc
    end)
  end

  @doc """
  Lists tasks. Options:

    * `:preloads` — list of associations to preload (defaults to a
      sensible "everything you need to render a row" set; pass `[]`
      for a bare list).
    * `:trader_slug` — filter by trader `normalized_name`.
    * `:faction` — `:usec` | `:bear` | nil. When given, returns
      faction-locked tasks for that faction *plus* faction-neutral
      tasks (where `faction_name` is `nil`). nil returns everything.
    * `:game_mode` — `:pvp`/`:pve` (or the DB strings). When given,
      returns only that mode's tasks. PVE is a distinct quest graph,
      so omitting this would merge both modes and show every quest
      twice (once per mode).
    * `:order_by` — defaults to `[asc: :name]`.
  """
  def list_tasks(opts \\ []) do
    preloads = Keyword.get(opts, :preloads, @default_preloads)
    order = Keyword.get(opts, :order_by, asc: :name)

    Task
    |> maybe_filter_by_trader(opts[:trader_slug])
    |> maybe_filter_by_faction(opts[:faction])
    |> maybe_filter_by_game_mode(opts[:game_mode])
    |> order_by(^order)
    |> preload(^preloads)
    |> Repo.all()
  end

  defp maybe_filter_by_game_mode(query, nil), do: query

  defp maybe_filter_by_game_mode(query, game_mode) do
    db = EftBuddy.GameMode.to_db(game_mode)
    from(t in query, where: t.game_mode == ^db)
  end

  defp maybe_filter_by_trader(query, nil), do: query

  defp maybe_filter_by_trader(query, slug) when is_binary(slug) do
    from(t in query,
      join: tr in assoc(t, :trader),
      where: tr.normalized_name == ^slug
    )
  end

  defp maybe_filter_by_faction(query, nil), do: query

  defp maybe_filter_by_faction(query, faction) when faction in [:usec, :bear] do
    # The API stores faction names uppercase ("USEC" / "BEAR").
    # Match faction-locked tasks for the given faction *and*
    # faction-neutral tasks (factionName: null), since most quests
    # are doable by either faction.
    name = faction |> Atom.to_string() |> String.upcase()

    from(t in query,
      where: is_nil(t.faction_name) or t.faction_name == ^name
    )
  end

  # ── Availability inputs ────────────────────────────────

  @doc """
  Returns a `%{task_id => MapSet.t(prerequisite_task_id)}` map
  built from `task_task_requirements` rows whose `status` array
  contains `"complete"`.

  Used by LiveViews to compute task availability on the fly without
  N+1 queries: each `TasksLive` row checks whether *all* of a task's
  prerequisites are present in the locally-tracked completed set.

  We filter to `"complete"` only because the chain UI cares about
  the same prerequisites the `task_unlocks` reverse index already
  uses (i.e. "the player must finish X before Y becomes available").
  Other statuses (`"active"`, `"failed"`) describe state machines we
  don't model in the v1 tracker.
  """
  def prereq_map(game_mode \\ nil) do
    Cache.fetch({__MODULE__, :prereq_map, game_mode}, ["TasksSync"], fn ->
      prereq_map_uncached(game_mode)
    end)
  end

  defp prereq_map_uncached(game_mode) do
    from(r in TaskRequirement,
      where: fragment("? = ANY(?)", "complete", r.status),
      select: {r.task_id, r.prerequisite_task_id}
    )
    |> maybe_scope_prereq_to_mode(game_mode)
    |> Repo.all()
    |> Enum.group_by(fn {task_id, _} -> task_id end, fn {_, prereq_id} -> prereq_id end)
    |> Map.new(fn {task_id, prereqs} -> {task_id, MapSet.new(prereqs)} end)
  end

  # Task ids are mode-specific UUIDs, so an unscoped prereq map is
  # already safe to use per mode (the other mode's ids simply never
  # get looked up). We still allow scoping to keep the map small and
  # the intent explicit.
  defp maybe_scope_prereq_to_mode(query, nil), do: query

  defp maybe_scope_prereq_to_mode(query, game_mode) do
    db = EftBuddy.GameMode.to_db(game_mode)
    from(r in query, join: t in assoc(r, :task), where: t.game_mode == ^db)
  end

  @doc """
  Lists traders that own at least one task in the DB.

  Driven from the actual data so the LiveView's filter chips never
  show traders with zero tasks (e.g. before a sync) and pick up new
  traders the API starts returning without a code change.

  Returns a list of `%EftBuddy.Hideout.Trader{}` ordered by name.
  """
  def traders_with_tasks(game_mode \\ nil) do
    Cache.fetch({__MODULE__, :traders_with_tasks, game_mode}, ["TasksSync"], fn ->
      traders_with_tasks_uncached(game_mode)
    end)
  end

  defp traders_with_tasks_uncached(game_mode) do
    from(tr in Trader,
      join: t in Task,
      on: t.trader_id == tr.id,
      distinct: true,
      order_by: tr.name
    )
    |> maybe_scope_traders_to_mode(game_mode)
    |> Repo.all()
  end

  defp maybe_scope_traders_to_mode(query, nil), do: query

  defp maybe_scope_traders_to_mode(query, game_mode) do
    db = EftBuddy.GameMode.to_db(game_mode)
    from([tr, t] in query, where: t.game_mode == ^db)
  end
end
