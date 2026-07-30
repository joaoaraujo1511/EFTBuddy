defmodule EftBuddy.Repo.Migrations.AddRenderingConfigToMaps do
  use Ecto.Migration

  @moduledoc """
  Moves the interactive-map rendering config from a hand-copied snapshot in
  `EftBuddy.Maps.Assets` into synced columns.

  The config lives in tarkov-dev's `src/data/maps.json`, which `Maps.Sync`
  already downloads every run for `svg_path` / `image_variants` — it just threw
  the projection fields away. Snapshotting them in code had already drifted:
  The Lab lost its "Technical" floor, Customs its "4th Floor" and Reserve four
  upper floors, and every map's labels were discarded.
  """

  def change do
    alter table(:maps) do
      # "svg" | "tile" — which kind of interactive base this map has.
      add :projection, :string
      # Affine game->pixel transform [scaleX, marginX, scaleZ, marginZ].
      # Note scaleX and scaleZ can differ (Icebreaker: 2.0 vs 3.5).
      add :transform, {:array, :float}
      add :coordinate_rotation, :float
      # [[x1, z1], [x2, z2]] projection box.
      add :bounds, {:array, {:array, :float}}
      # Overrides `bounds` for marker projection when the SVG registers
      # against a different box (Reserve).
      add :svg_bounds, {:array, {:array, :float}}
      add :min_zoom, :integer
      add :max_zoom, :integer
      # Tile maps only.
      add :tile_size, :integer
      add :tile_path, :string
      # [min, max] height covering the base floor.
      add :height_range, {:array, :float}
      # Toggleable floors: [%{"name", "id", "svgLayer", "tileUrl", "extents"}].
      # An entry may carry `tileUrl` on an SVG base map (Customs 4th floor,
      # Reserve upper floors), so floors are not all-SVG or all-tile.
      add :layers, {:array, :map}, default: []
      # Room / area names: [%{"position", "text", "top", "bottom", "size"}].
      add :labels, {:array, :map}, default: []
      # Credit for the interactive base art (e.g. Icebreaker -> TarkovBOT.eu).
      add :image_author, :string
      add :image_author_link, :string
    end
  end
end
