defmodule EftBuddy.Maps.Extract do
  @moduledoc """
  A map exit / extraction point (tarkov.dev `MapExtract`).

  `faction` is `"pmc"`, `"scav"` or `"shared"`. Item-gated extracts
  carry a `transfer_item` (the item to hand over) and a count — the
  link target for the Items tab.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_extracts" do
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

  def changeset(extract, attrs) do
    extract
    |> cast(attrs, [
      :map_id,
      :external_id,
      :name,
      :faction,
      :transfer_item_id,
      :transfer_item_count,
      :pos_x,
      :pos_y,
      :pos_z
    ])
    |> validate_required([:map_id, :external_id, :name])
    |> unique_constraint([:map_id, :external_id])
    |> foreign_key_constraint(:map_id)
    |> foreign_key_constraint(:transfer_item_id)
  end
end
