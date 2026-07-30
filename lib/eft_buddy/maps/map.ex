defmodule EftBuddy.Maps.Map do
  @moduledoc """
  An in-game map / location (Customs, Woods, Streets of Tarkov, …).

  Promoted from a bare `name`/`normalized_name` row (originally seeded
  as a side-effect of `EftBuddy.Tasks.Sync`) into a first-class entity
  owned by `EftBuddy.Maps.Sync`, which pulls the full tarkov.dev `maps`
  query: lore, raid parameters, bosses, extracts, transits, locks,
  access keys and hazards. The interactive-map `svg_path` is sourced
  separately from tarkov.dev's `maps.json` (the GraphQL API exposes no
  imagery).

  The DB table is still `"maps"`, so the `tasks.map_id` /
  `task_objective_maps.map_id` foreign keys are unaffected by the module
  move from `EftBuddy.Tasks.Map`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias EftBuddy.Maps.{
    AccessKey,
    Boss,
    Extract,
    Hazard,
    Lock,
    LootContainer,
    Spawn,
    StationaryWeapon,
    Switch,
    Transit,
    Variant
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "maps" do
    field :external_id, :string
    field :name, :string
    field :normalized_name, :string

    field :tarkov_data_id, :string
    field :name_id, :string
    field :wiki, :string
    field :svg_path, :string
    # Static map-image renders (flat "2D" / "3D") from tarkov.dev's
    # `maps.json`, keyed by projection: %{"2d" => [...], "3d" => [...]}.
    # Each entry: %{"key", "url", "label", "author"}. Drives the viewer's
    # 2D / 3D mode toggle and variant looping. See `EftBuddy.Maps.Sync`.
    field :image_variants, :map, default: %{}
    field :description, :string
    field :enemies, {:array, :string}, default: []
    field :raid_duration, :integer
    field :players, :string
    field :min_player_level, :integer
    field :max_player_level, :integer
    field :access_keys_min_player_level, :integer

    # ── Interactive-viewer rendering config ──────────────
    # Synced from tarkov-dev's `src/data/maps.json` (see `EftBuddy.Maps.Sync`)
    # rather than snapshotted in code, so upstream fixes and new floors arrive
    # on the next sync instead of silently drifting.
    field :projection, :string
    field :transform, {:array, :float}
    field :coordinate_rotation, :float
    field :bounds, {:array, {:array, :float}}
    field :svg_bounds, {:array, {:array, :float}}
    field :min_zoom, :integer
    field :max_zoom, :integer
    field :tile_size, :integer
    field :tile_path, :string
    field :height_range, {:array, :float}
    field :layers, {:array, :map}, default: []
    field :labels, {:array, :map}, default: []
    field :image_author, :string
    field :image_author_link, :string

    has_many :tasks, EftBuddy.Tasks.Task, foreign_key: :map_id

    has_many :variants, Variant, foreign_key: :map_id

    has_many :bosses, Boss, foreign_key: :map_id
    has_many :extracts, Extract, foreign_key: :map_id
    has_many :transits, Transit, foreign_key: :map_id
    has_many :locks, Lock, foreign_key: :map_id
    has_many :hazards, Hazard, foreign_key: :map_id
    has_many :access_keys, AccessKey, foreign_key: :map_id
    has_many :spawns, Spawn, foreign_key: :map_id
    has_many :loot_containers, LootContainer, foreign_key: :map_id
    has_many :stationary_weapons, StationaryWeapon, foreign_key: :map_id
    has_many :switches, Switch, foreign_key: :map_id

    timestamps()
  end

  def changeset(map, attrs) do
    map
    |> cast(attrs, [
      :external_id,
      :name,
      :normalized_name,
      :tarkov_data_id,
      :name_id,
      :wiki,
      :svg_path,
      :image_variants,
      :description,
      :enemies,
      :raid_duration,
      :players,
      :min_player_level,
      :max_player_level,
      :access_keys_min_player_level,
      :projection,
      :transform,
      :coordinate_rotation,
      :bounds,
      :svg_bounds,
      :min_zoom,
      :max_zoom,
      :tile_size,
      :tile_path,
      :height_range,
      :layers,
      :labels,
      :image_author,
      :image_author_link
    ])
    |> validate_required([:external_id, :name, :normalized_name])
    |> unique_constraint(:external_id)
    |> unique_constraint(:normalized_name)
  end
end
