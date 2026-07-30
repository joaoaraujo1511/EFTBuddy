defmodule EftBuddy.Maps.StationaryWeapon do
  @moduledoc """
  A mounted stationary weapon emplacement on a map (tarkov.dev
  `MapStationaryWeapon`). One row per physical position; `name` /
  `normalized_name` are resolved from tarkov.dev's stationary-weapon
  index. `pos_x`/`pos_z` project onto the viewer (`pos_y` is height).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_stationary_weapons" do
    belongs_to :map, EftBuddy.Maps.Map

    field :name, :string
    field :normalized_name, :string

    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end

  def changeset(weapon, attrs) do
    weapon
    |> cast(attrs, [:map_id, :name, :normalized_name, :pos_x, :pos_y, :pos_z])
    |> validate_required([:map_id])
    |> foreign_key_constraint(:map_id)
  end
end
