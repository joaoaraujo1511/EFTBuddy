defmodule EftBuddy.Maps do
  @moduledoc """
  The Maps context. Reads maps and their sub-entities (bosses,
  extracts, transits, locks, hazards, access keys, spawns, stationary
  weapons, loot containers) for the LiveView to render the maps list /
  detail pages.

  Data is populated by `EftBuddy.Maps.Sync` (run on boot by
  `EftBuddy.Sync.Bootstrap`, or manually from IEx). See that module's
  docs for the field shapes.

  The `Map` schema is aliased as `GameMap` throughout so it doesn't
  shadow the stdlib `Map` module used for the count helpers below.
  """

  import Ecto.Query

  alias EftBuddy.Maps.Boss
  alias EftBuddy.Maps.Bosses
  alias EftBuddy.Maps.Map, as: GameMap
  alias EftBuddy.Repo
  alias EftBuddy.Tasks.{Objective, ObjectiveMap, Task}

  @doc """
  Bosses regrouped into one entry per identity — see `EftBuddy.Maps.Bosses`.

  Both the index chips and the detail cards go through here, so they can't
  disagree about how many bosses a map has.
  """
  defdelegate group_bosses(bosses), to: Bosses, as: :group

  @doc "Escort label with its count, e.g. `\"Rogue x3\"`."
  defdelegate escort_label(escort), to: Bosses

  @doc "Render a 0.0-1.0 chance as a whole-percent label, or a dash."
  defdelegate percent_label(chance), to: Bosses

  @doc "Human label for a raw `spawn_trigger`."
  defdelegate trigger_label(trigger), to: Bosses

  # Locations deliberately kept off the Maps tab, with the reason. This is a
  # short, judgement-call blacklist — the *structural* guard is
  # `has_imagery?/1` below, not this list.
  #
  #   * `night-factory`  — a raid variant of `factory`, shown as a Day/Night
  #                        chip on that one card (see `EftBuddy.Maps.Sync`).
  #   * `ground-zero-21` — the payload the `ground-zero` row is built from, not
  #                        a card of its own. Its task links are aliased onto
  #                        Ground Zero rather than dropped (see `@aliases`).
  #   * `the-lab-dark`   — an event-only variant of The Lab. Event-specific map
  #                        versions are out of scope.
  #
  # Also filtered as a defensive net because `Tasks.Sync` can seed bare map
  # rows, so a stray row never reaches the UI.
  @blacklisted_slugs %{
    "night-factory" => "raid variant of factory",
    "ground-zero-21" => "canonical data source for ground-zero",
    "the-lab-dark" => "event-only variant of the-lab"
  }

  # Not a visibility judgement — these simply aren't raids on a map, so they
  # should never become a row at all. `has_imagery?/1` would hide the tutorial
  # anyway (it has no art anywhere upstream), but there's no reason to carry a
  # bare row for it.
  @never_seeded ~w(ground-zero-tutorial)

  @doc """
  Slugs that must never be seeded as their own map row. Consumed by
  `EftBuddy.Tasks.Sync`, which resolves the variant ones through
  `alias_slug/1` instead of discarding the task links that point at them.
  """
  def excluded_slugs, do: Map.keys(@blacklisted_slugs) ++ @never_seeded

  # Variant slugs that resolve onto a canonical map row. Without this, task
  # references to a hidden variant are silently dropped and the quest badge
  # understates reality: `night-factory` carries 59 objective references and
  # `ground-zero-21` another 37, all of which used to vanish.
  #
  # `ground-zero-tutorial` is deliberately absent — it is a scripted onboarding
  # instance, not a raid on the map, so its single reference stays dropped.
  @aliases %{
    "night-factory" => "factory",
    "ground-zero-21" => "ground-zero"
  }

  @doc """
  Canonical map slug for a possibly-variant slug. Returns the input unchanged
  when it is already canonical.
  """
  def alias_slug(slug) when is_binary(slug), do: Map.get(@aliases, slug, slug)
  def alias_slug(other), do: other

  # Boss rows are grouped for display by first appearance, which only means
  # anything if the order is stable. Unordered, the preload returns Postgres
  # heap order, so a re-sync or a VACUUM could silently demote a map's headline
  # boss. `position` is the API's own ordering, synced explicitly.
  @boss_order from(b in Boss, order_by: [asc: b.position, asc: b.id])

  # Everything the detail page needs, with the second-level joins
  # materialized so the template renders item / destination-map links
  # without N+1 queries.
  @detail_preloads [
    :hazards,
    :spawns,
    :loot_containers,
    :stationary_weapons,
    :switches,
    :variants,
    [bosses: {@boss_order, :variant}],
    [extracts: :transfer_item],
    [transits: :destination_map],
    [locks: :key_item],
    [access_keys: :item]
  ]

  @doc """
  Whether a map should appear on the Maps tab.

  Two independent gates:

    * not blacklisted (a short list of judgement calls — variants and event
      maps, see `@blacklisted_slugs`);
    * has *some* usable imagery — an interactive base, or a flat 2D/3D render.

  The imagery gate is what replaced the old hand-maintained allowlist. A
  location with no art in tarkov-dev's `maps.json` is precisely a location
  upstream hasn't finished, so half-built maps stay hidden automatically and a
  newly released one appears as soon as art exists — no code change either way.
  It also excludes `ground-zero-tutorial` on its own merits, since that has no
  art anywhere upstream.
  """
  def visible?(%GameMap{} = map) do
    not Map.has_key?(@blacklisted_slugs, map.normalized_name) and has_imagery?(map)
  end

  def visible?(_), do: false

  @doc "Whether a map has any renderable imagery (interactive base or flat render)."
  def has_imagery?(%GameMap{} = map) do
    map.projection in ["svg", "tile"] or map_size(map.image_variants || %{}) > 0
  end

  def has_imagery?(_), do: false

  # ── Reads ──────────────────────────────────────────────

  @doc """
  Lists maps for the index grid, ordered by name. Preloads `:bosses`
  so the cards can show boss portraits/names without a follow-up query.

  Options:
    * `:order_by` — defaults to `[asc: :name]`.
  """
  def list_maps(opts \\ []) do
    order = Keyword.get(opts, :order_by, asc: :name)
    blacklisted = Map.keys(@blacklisted_slugs)

    GameMap
    |> where([m], m.normalized_name not in ^blacklisted)
    |> order_by(^order)
    # `access_keys` drives the "key required" filter on the index; `bosses`
    # feeds the card portraits.
    |> preload(bosses: ^@boss_order, access_keys: [])
    |> Repo.all()
    # The imagery half of the gate needs `image_variants` / `projection`, so it
    # runs in Elixir rather than as a second SQL predicate.
    |> Enum.filter(&visible?/1)
  end

  @doc """
  Returns a single map by its `normalized_name` slug with every
  association needed to render the detail page, or `nil` if no map with
  that slug exists.
  """
  def get_map_by_slug(slug) when is_binary(slug) do
    if Map.has_key?(@blacklisted_slugs, slug) do
      nil
    else
      from(m in GameMap, where: m.normalized_name == ^slug)
      |> preload(^@detail_preloads)
      |> Repo.one()
      |> then(fn map -> if map && visible?(map), do: map, else: nil end)
    end
  end

  def get_map_by_slug(_), do: nil

  @doc """
  Returns a `%{map_id => quest_count}` map for the index badges, counting
  tasks whose *primary* map is this one (`tasks.map_id`) plus tasks with
  at least one objective on the map (via `task_objective_maps`).

  Counted in Postgres. This used to pull both whole tables into the BEAM and
  build a `MapSet` per map just to take its size — thousands of rows marshalled
  on every index mount to produce about twenty integers.
  """
  def quest_counts do
    primary =
      from(t in Task, where: not is_nil(t.map_id), select: %{map_id: t.map_id, task_id: t.id})

    via_objectives =
      from(om in ObjectiveMap,
        join: o in Objective,
        on: o.id == om.objective_id,
        where: not is_nil(o.task_id),
        select: %{map_id: om.map_id, task_id: o.task_id}
      )

    # `union` (not `union_all`) so a task counted both ways isn't double-counted
    # — the same job the MapSet used to do.
    pairs = union(primary, ^via_objectives)

    from(p in subquery(pairs),
      group_by: p.map_id,
      select: {p.map_id, count(p.task_id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
