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

  # Every read here is owned by this syncer: nothing else writes the hideout
  # tables, so its completion is exactly when a cached answer stops being true.
  @source "HideoutSync"

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
    query =
      from(l in StationLevel,
        join: s in assoc(l, :station),
        where: s.normalized_name == ^slug and l.level == ^level,
        preload: [
          item_requirements: ^item_requirements_query(),
          station_level_requirements: [:required_station],
          skill_requirements: [:skill],
          trader_requirements: [:trader]
        ]
      )

    case Repo.one(query) do
      nil ->
        nil

      level_row ->
        %{
          item_requirements: level_row.item_requirements,
          station_level_requirements: level_row.station_level_requirements,
          skill_requirements: level_row.skill_requirements,
          trader_requirements: level_row.trader_requirements
        }
    end
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
  """
  def get_level_requirements_for([]), do: %{}

  def get_level_requirements_for(pairs) when is_list(pairs) do
    # Sorted so two callers asking for the same set in a different order share an
    # entry instead of each populating their own.
    Cache.fetch(
      {__MODULE__, :level_requirements_for, Enum.sort(pairs)},
      [@source],
      fn -> get_level_requirements_for_uncached(pairs) end
    )
  end

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
      [@source],
      fn -> get_total_item_cost_uncached(slug, up_to_level) end
    )
  end

  def get_total_item_cost(_, _), do: []

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
