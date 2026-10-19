defmodule EftBuddy.Maps.Switch do
  @moduledoc """
  An interactable switch / lever on a map (tarkov.dev `MapSwitch`) —
  extract levers, power switches and the like. One row per switch.
  `switch_type` mirrors the API (`"Open"` / `"Close"`); `pos_x`/`pos_z`
  project onto the viewer (`pos_y` is height).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_switches" do
    # "regular" | "pve": upstream publishes map data per mode.
    field :game_mode, :string, default: "regular"
    belongs_to :map, EftBuddy.Maps.Map

    field :external_id, :string
    field :switch_type, :string

    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end
end
