defmodule EftBuddy.Maps.Spawn do
  @moduledoc """
  A positioned spawn point on a map (tarkov.dev `MapSpawn`).

  Every spawn marker the viewer draws comes from these rows — one row per
  physical spawn point (`pos_x`/`pos_z` project onto the viewer; `pos_y` is
  height). `spawn_type` is the coarse classification:

    * `"pmc"`         — player (PMC) insertion points
    * `"scav"`        — scav-side (AI) spawn points
    * `"sniper_scav"` — scav sniper nests (own category upstream)
    * `"boss"`        — boss-eligible spawn points

  A `"boss"` row is not necessarily a boss pin. `EftBuddyWeb.MapsLive.Markers`
  joins `zone_name` against `EftBuddy.Maps.Boss`'s
  `spawn_locations[].spawn_key`: claimed points become that boss's pin,
  unclaimed ones are ordinary scav points (which is what they are — 391 of
  them across the roster, 164 on Streets alone).

  `sides` and `categories` are the API's raw arrays, kept because that join
  happens at read time and the rule for unclaimed points depends on them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_spawns" do
    belongs_to :map, EftBuddy.Maps.Map

    field :spawn_type, :string
    field :zone_name, :string
    field :sides, {:array, :string}, default: []
    field :categories, {:array, :string}, default: []

    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end

  def changeset(spawn, attrs) do
    spawn
    |> cast(attrs, [
      :map_id,
      :spawn_type,
      :zone_name,
      :sides,
      :categories,
      :pos_x,
      :pos_y,
      :pos_z
    ])
    |> validate_required([:map_id, :spawn_type])
    |> foreign_key_constraint(:map_id)
  end
end
