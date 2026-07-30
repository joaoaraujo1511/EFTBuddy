defmodule EftBuddy.Maps.Hazard do
  @moduledoc """
  An environmental hazard zone (tarkov.dev `MapHazard`) — sniper lines,
  minefields, mortar / artillery strike zones (folded in from the map's
  separate `artillery.zones`) and the generic "hazard" kind (The
  Labyrinth's chamber traps). The API lists one entry per position; we
  collapse identical `(hazard_type, name)` tuples into a single row with
  a `count` and the full list of `positions` (so the viewer can plot the
  whole minefield / sniper zone). `pos_x`/`pos_y`/`pos_z` remain as a
  representative pin for backward compatibility.

      positions :: [%{"x" => float(), "y" => float(), "z" => float()}]
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_hazards" do
    belongs_to :map, EftBuddy.Maps.Map

    field :hazard_type, :string
    field :name, :string
    field :count, :integer, default: 1
    field :positions, {:array, :map}, default: []

    # Game-world position of a representative hazard in the collapsed
    # group (Y is height; the viewer projects X/Z).
    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end

  def changeset(hazard, attrs) do
    hazard
    |> cast(attrs, [:map_id, :hazard_type, :name, :count, :positions, :pos_x, :pos_y, :pos_z])
    |> validate_required([:map_id])
    |> unique_constraint([:map_id, :hazard_type, :name])
    |> foreign_key_constraint(:map_id)
  end
end
