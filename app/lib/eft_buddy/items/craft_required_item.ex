defmodule EftBuddy.Items.CraftRequiredItem do
  @moduledoc """
  Input side of a craft: the items consumed by the recipe.
  See `EftBuddy.Items.BarterRequiredItem` for the meaning of
  `count`, `quantity`, and `attributes` — same conventions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_craft_required_items" do
    field(:count, :integer)
    field(:quantity, :integer)
    field(:attributes, :map, default: %{})

    belongs_to(:craft, EftBuddy.Items.Craft)
    belongs_to(:item, EftBuddy.Items.Item)

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:count, :quantity, :attributes, :craft_id, :item_id])
    |> validate_required([:count, :quantity, :craft_id, :item_id])
    |> validate_number(:count, greater_than: 0)
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:craft_id)
    |> foreign_key_constraint(:item_id)
  end
end
