defmodule EftBuddy.Hideout.ItemRequirement do
  @moduledoc """
  An item the player must spend to build/upgrade a station to a given
  level. Stores only a foreign key into `EftBuddy.Items.Item` and a
  quantity — name, icon, prices and everything else are read through
  the FK so they stay fresh with the items sync.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_item_requirements" do
    field :quantity, :integer
    # The upgrade only accepts the item found in raid.
    field :found_in_raid, :boolean, default: false

    belongs_to :level, EftBuddy.Hideout.StationLevel
    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end
end
