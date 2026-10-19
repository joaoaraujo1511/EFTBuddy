defmodule EftBuddy.Maps.LootContainer do
  @moduledoc """
  A hidden stash / cache on a map (tarkov.dev `MapLootContainer`).

  We only persist the cache-type containers (buried barrel caches and
  ground caches) — the "stash" marker layer — rather than every
  loose-loot container the API lists, to keep the table small and the
  map readable. `pos_x`/`pos_z` project onto the viewer (`pos_y` is
  height).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_loot_containers" do
    # "regular" | "pve": upstream publishes map data per mode.
    field :game_mode, :string, default: "regular"
    belongs_to :map, EftBuddy.Maps.Map

    field :name, :string
    field :normalized_name, :string

    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end
end
