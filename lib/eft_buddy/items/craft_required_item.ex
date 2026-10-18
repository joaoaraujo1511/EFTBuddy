defmodule EftBuddy.Items.CraftRequiredItem do
  @moduledoc """
  Input side of a craft: the items consumed by the recipe.
  See `EftBuddy.Items.BarterRequiredItem` for the meaning of
  `count`, `quantity`, and `attributes` — same conventions.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_craft_required_items" do
    field(:count, :decimal)
    field(:quantity, :decimal)
    field(:attributes, :map, default: %{})
    # Set instead of `item_id` when upstream names a quest item it doesn't
    # define yet; see the migration that added it.
    field(:unresolved_external_id, :string)

    belongs_to(:craft, EftBuddy.Items.Craft)
    belongs_to(:item, EftBuddy.Items.Item)

    timestamps()
  end
end
