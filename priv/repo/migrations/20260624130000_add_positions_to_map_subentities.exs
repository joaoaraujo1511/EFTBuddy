defmodule EftBuddy.Repo.Migrations.AddPositionsToMapSubentities do
  use Ecto.Migration

  @moduledoc """
  Phase C of the interactive maps feature: re-add the game-world
  coordinates (`pos_x`, `pos_y`, `pos_z`) to the map sub-entities so the
  in-app viewer can plot clickable markers.

  `EftBuddy.Maps.Sync` originally dropped the x/y/z clouds (there was no
  renderer to use them). Now that the self-hosted viewer can project
  game coords onto the SVG, we keep one position per row:

    * `map_extracts` / `map_transits` — one row per entity, so the
      position is exact.
    * `map_locks` / `map_hazards` — rows are collapsed by identity +
      `count`, so the position is the first occurrence in the group (a
      representative pin; the count stays in the text list).

  All three columns are nullable floats — every sub-entity predates this
  migration, and the API can omit `position` — so a missing coordinate
  just yields no marker. `Y` is the vertical/height axis; the projection
  uses `X` and `Z`.
  """

  @tables [:map_extracts, :map_transits, :map_locks, :map_hazards]

  def change do
    for table <- @tables do
      alter table(table) do
        add :pos_x, :float
        add :pos_y, :float
        add :pos_z, :float
      end
    end
  end
end
