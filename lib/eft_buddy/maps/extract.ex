defmodule EftBuddy.Maps.Extract do
  @moduledoc """
  A map exit / extraction point (tarkov.dev `MapExtract`).

  `faction` is `"pmc"`, `"scav"` or `"shared"`. Item-gated extracts
  carry a `transfer_item` (the item to hand over) and a count — the
  link target for the Items tab.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_extracts" do
    # "regular" | "pve": upstream publishes map data per mode.
    field :game_mode, :string, default: "regular"
    belongs_to :map, EftBuddy.Maps.Map

    field :external_id, :string
    field :name, :string
    field :faction, :string

    belongs_to :transfer_item, EftBuddy.Items.Item, foreign_key: :transfer_item_id
    field :transfer_item_count, :float

    # Game-world position (Y is height; the viewer projects X/Z).
    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end
end
