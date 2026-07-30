defmodule EftBuddy.Hideout.ItemRequirement do
  @moduledoc """
  An item the player must spend to build/upgrade a station to a given
  level. Stores only a foreign key into `EftBuddy.Items.Item` and a
  quantity — name, icon, prices and everything else are read through
  the FK so they stay fresh with the items sync.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_item_requirements" do
    field :quantity, :integer

    belongs_to :level, EftBuddy.Hideout.StationLevel
    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end

  def changeset(item_requirement, attrs) do
    item_requirement
    |> cast(attrs, [:quantity, :level_id, :item_id])
    |> validate_required([:quantity, :level_id, :item_id])
    |> validate_number(:quantity, greater_than: 0)
    |> unique_constraint([:level_id, :item_id])
    |> foreign_key_constraint(:level_id)
    |> foreign_key_constraint(:item_id)
  end
end
