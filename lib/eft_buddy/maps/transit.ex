defmodule EftBuddy.Maps.Transit do
  @moduledoc """
  A transit — an in-raid crossing from one map to another (tarkov.dev
  `MapTransit`). `destination_map` points at the `maps` row the transit
  leads to (resolved within the sync pass; nullable until the
  destination is known).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_transits" do
    # "regular" | "pve": upstream publishes map data per mode.
    field :game_mode, :string, default: "regular"
    belongs_to :map, EftBuddy.Maps.Map

    field :external_id, :string
    field :description, :string
    field :conditions, :string

    belongs_to :destination_map, EftBuddy.Maps.Map, foreign_key: :destination_map_id

    # Game-world position (Y is height; the viewer projects X/Z).
    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end
end
