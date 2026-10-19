defmodule EftBuddy.Items.CraftRewardItem do
  @moduledoc """
  Output side of a craft: the items produced by the recipe.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_craft_reward_items" do
    field(:count, :integer)
    field(:quantity, :integer)

    belongs_to(:craft, EftBuddy.Items.Craft)
    belongs_to(:item, EftBuddy.Items.Item)

    timestamps()
  end
end
