defmodule EftBuddy.Hideout do
  @moduledoc """
  The Hideout context. Reads stations, levels, and per-level
  requirements (items, prerequisite stations, skills, traders) for
  the LiveView to render the hideout grid.

  Data is populated by `EftBuddy.Hideout.Sync` from the Tarkov.dev
  GraphQL API once at boot (via `EftBuddy.Sync.Bootstrap`) and on
  demand when a dev calls `EftBuddy.Hideout.Sync.run/0` manually.
  """

  import Ecto.Query

  alias EftBuddy.Cache
  alias EftBuddy.Repo

  # The hideout tables themselves have exactly one writer.
  @source "HideoutSync"

  # But the requirement reads EMBED items. `item_requirements` preloads
  # `[item: i]`, and the grid renders `r.item.name` and `r.item.icon_link`, so a
  # rename or a new icon from ItemsSync changes what those entries should say.
  # Keyed on HideoutSync alone they would keep the old name until the next
  # hideout sync — a DAILY feed. `cache_source_map_test.exs` exists to catch
  # exactly this class of under-declaration; the hideout entries were simply
  # never covered by it.
  @requirement_sources [@source, "ItemsSync"]

  alias EftBuddy.Hideout.{
    ItemRequirement,
    Station,
    StationLevel
  }

  # ── Stations ───────────────────────────────────────────

  @doc """
  Returns one summary map per station for the hideout grid:

      %{slug: "medstation", name: "Medstation", max: 3}

  Sorted by `name`. The actual per-level requirements are loaded
  separately via `get_level_requirements/2` so we don't fetch every
  level's items for every card on initial mount.
  """
  def list_modules do
    Cache.fetch({__MODULE__, :list_modules}, [@source], &list_modules_uncached/0)
  end

  defp list_modules_uncached do
    from(s in Station,
      left_join: l in assoc(s, :levels),
      group_by: s.id,
      order_by: s.name,
      select: %{
        slug: s.normalized_name,
        name: s.name,
        max: coalesce(max(l.level), 0)
      }
    )
    |> Repo.all()
  end

  # ── Level requirements ─────────────────────────────────

  @doc """
  Returns the requirements for a specific (station_slug, level)
  pair, with FKs preloaded. Returns `nil` if either the station or
  the level doesn't exist.

  The returned shape has four keys — `:item_requirements`,
  `:station_level_requirements`, `:skill_requirements`,
  `:trader_requirements` — each a list of preloaded structs ready
  to be rendered.
  """
  def get_level_requirements(slug, level)
      when is_binary(slug) and is_integer(level) and level >= 1 do
    # Delegates rather than issuing its own query, so there is exactly ONE read
    # path for hideout requirements. The single-pair version used to be
    # uncached, which made it invisible to every warming and invalidation
    # mechanism in the app — and it was the version the LiveView reached on a
    # fresh mount, once per station.
    [{slug, level}]
    |> get_level_requirements_for()
    |> Map.get({slug, level})
  end

  def get_level_requirements(_, _), do: nil

  @doc """
  Batched `get_level_requirements/2`: takes `[{slug, level}]` and returns a map
  keyed by that same `{slug, level}` tuple, with identical values.

  This exists because calling `get_level_requirements/2` once per station is an
  N+1, and on a remote database that is the difference between a page that loads
  and one that does not. The hideout grid mounts 26 stations; each call cost one
  query for the level plus one per preloaded association, so the connected mount
  issued **155 queries and took 7.1 seconds** against a hosted database at ~76ms
  round-trip. Batched, the association preloads run once for the whole set
  instead of once per station, so the query count stops scaling with the number
  of stations.

  The cost of a round trip is what makes this matter, not the cost of the query:
  every one of those 155 queries was individually trivial. Against a database on
  localhost the same N+1 is invisible, which is exactly why it survived.

  ## Caching is per PAIR, not per request

  Each `{slug, level}` gets its own entry and the batched query fills only the
  ones that missed. That keeps both properties at once: the N+1 cannot come back
  (one query for the whole miss set) and the entries are shared by every visitor
  (one per row in `hideout_station_levels`, about eighty).

  This used to cache on the whole sorted pair list instead. That was survivable
  only because the single caller always asked for the same all-stations-at-base
  set, so there was exactly one key. The moment a caller passes an operator's
  actual board — which is what the level-restore path needs to do — that key
  becomes the product of every station's level, near enough per-visitor, missing
  almost always, and evicting the genuinely shared entries to store it. It is
  the pattern `EftBuddy.Cache`'s own moduledoc rules out, and it cannot be
  warmed ahead of time because the server cannot enumerate boards nobody has
  visited yet.
  """
  def get_level_requirements_for([]), do: %{}

  def get_level_requirements_for(pairs) when is_list(pairs) do
    pairs = Enum.uniq(pairs)

    pairs
    |> Enum.map(&cache_key/1)
    |> Cache.fetch_many(@requirement_sources, fn missing_keys ->
      missing_keys
      |> Enum.map(&pair_from_key/1)
      |> get_level_requirements_for_uncached()
      |> Map.new(fn {pair, reqs} -> {cache_key(pair), reqs} end)
    end)
    |> Map.new(fn {key, reqs} -> {pair_from_key(key), reqs} end)
  end

  defp cache_key({slug, level}), do: {__MODULE__, :level_requirements, slug, level}
  defp pair_from_key({__MODULE__, :level_requirements, slug, level}), do: {slug, level}

  defp get_level_requirements_for_uncached(pairs) do
    # Grouped by level so the WHERE clause stays exact rather than fetching the
    # cartesian product of every requested slug against every requested level.
    # In practice this is one OR-group per distinct level, and the hideout grid
    # asks for a handful.
    conditions =
      pairs
      |> Enum.group_by(fn {_slug, level} -> level end, fn {slug, _level} -> slug end)
      |> Enum.reduce(dynamic(false), fn {level, slugs}, acc ->
        dynamic([l, s], ^acc or (s.normalized_name in ^slugs and l.level == ^level))
      end)

    from(l in StationLevel,
      join: s in assoc(l, :station),
      where: ^conditions,
      preload: [
        # `station: s` reuses the join above rather than issuing another query
        # just to learn the slug we key the result map by.
        station: s,
        item_requirements: ^item_requirements_query(),
        station_level_requirements: [:required_station],
        skill_requirements: [:skill],
        trader_requirements: [:trader]
      ]
    )
    |> Repo.all()
    |> Map.new(fn level_row ->
      {{level_row.station.normalized_name, level_row.level},
       %{
         item_requirements: level_row.item_requirements,
         station_level_requirements: level_row.station_level_requirements,
         skill_requirements: level_row.skill_requirements,
         trader_requirements: level_row.trader_requirements
       }}
    end)
  end

  @doc """
  Returns the cumulative item cost of building a station from level 1
  up to (and including) `up_to_level`. Quantities are summed per item
  across every level in the range, so a station that needs 50,000
  Roubles at lvl 1 and 150,000 at lvl 2 reports 200,000 total at
  `up_to_level: 2`.

  Each entry in the returned list is a map of `%{item: %Item{}, quantity: integer}`,
  ordered with Roubles first then alphabetically — same convention
  the level requirements use. Returns `[]` when the station has no
  levels in the range.
  """
  def get_total_item_cost(slug, up_to_level)
      when is_binary(slug) and is_integer(up_to_level) and up_to_level >= 1 do
    Cache.fetch(
      {__MODULE__, :total_item_cost, slug, up_to_level},
      # Selects `item: i`, so ItemsSync owns half of what this renders. Same
      # under-declaration as the requirement reads above.
      @requirement_sources,
      fn -> get_total_item_cost_uncached(slug, up_to_level) end
    )
  end

  def get_total_item_cost(_, _), do: []

  # ── Warming ────────────────────────────────────────────

  @doc false
  # Every `{slug, level}` the grid can ask for, in one batched read.
  #
  # Possible precisely because the entries are per-pair: this covers EVERY
  # operator's board, not just the all-at-base-level one the old whole-list key
  # could hold. Two queries — the pair list, then the batch.
  def warm_level_requirements do
    pairs =
      from(l in StationLevel,
        join: s in assoc(l, :station),
        select: {s.normalized_name, l.level}
      )
      |> Repo.all()

    get_level_requirements_for(pairs)

    {:ok, length(pairs)}
  end

  @doc false
  # `populate_items_used/1` in the LiveView fires for every station at MAX
  # level, so an operator with a fully built hideout pays one of these per
  # station on the first mount after each sync. Warming with `max` matches that
  # call site exactly — warming any other level would populate keys the UI never
  # reads.
  def warm_total_item_costs do
    modules = Enum.filter(list_modules(), &(&1.max >= 1))

    for %{slug: slug, max: max} <- modules, do: get_total_item_cost(slug, max)

    {:ok, length(modules)}
  end

  defp get_total_item_cost_uncached(slug, up_to_level) do
    query =
      from(r in ItemRequirement,
        join: l in assoc(r, :level),
        join: s in assoc(l, :station),
        join: i in assoc(r, :item),
        where: s.normalized_name == ^slug and l.level <= ^up_to_level,
        group_by: [i.id, i.name, i.normalized_name],
        select: %{
          item_id: i.id,
          item: i,
          quantity: sum(r.quantity)
        },
        order_by: [
          desc: fragment("CASE WHEN ? = 'roubles' THEN 1 ELSE 0 END", i.normalized_name),
          asc: i.name
        ]
      )

    Repo.all(query)
  end

  # Roubles first, then by item name. Matches how the in-game UI
  # tends to list build costs (currency cost on top).
  defp item_requirements_query do
    from(r in ItemRequirement,
      join: i in assoc(r, :item),
      preload: [item: i],
      order_by: [
        desc: fragment("CASE WHEN ? = 'roubles' THEN 1 ELSE 0 END", i.normalized_name),
        asc: i.name
      ]
    )
  end
end
