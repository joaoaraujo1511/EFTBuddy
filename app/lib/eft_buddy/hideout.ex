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

  alias EftBuddy.Repo

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

  def get_total_item_cost(_, _), do: []

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
