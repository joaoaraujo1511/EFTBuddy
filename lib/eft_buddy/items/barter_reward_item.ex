defmodule EftBuddy.Items.BarterRewardItem do
  @moduledoc """
  Output side of a barter: the items the player receives.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_barter_reward_items" do
    field(:count, :integer)
    field(:quantity, :integer)

    belongs_to(:barter, EftBuddy.Items.Barter)
    belongs_to(:item, EftBuddy.Items.Item)

    timestamps()
  end
end
