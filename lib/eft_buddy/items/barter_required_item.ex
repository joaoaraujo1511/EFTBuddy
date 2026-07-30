defmodule EftBuddy.Items.BarterRequiredItem do
  @moduledoc """
  Input side of a barter: the items the player must hand over.

  `count` is the per-stack size, `quantity` is the number of stacks;
  in practice they're usually equal but the API distinguishes them
  so we preserve both. `attributes` is a free-form jsonb map for
  the rare cases where the API tags the requirement with extra
  metadata (e.g. dogtag minLevel).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_barter_required_items" do
    field(:count, :integer)
    field(:quantity, :integer)
    field(:attributes, :map, default: %{})

    belongs_to(:barter, EftBuddy.Items.Barter)
    belongs_to(:item, EftBuddy.Items.Item)

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:count, :quantity, :attributes, :barter_id, :item_id])
    |> validate_required([:count, :quantity, :barter_id, :item_id])
    |> validate_number(:count, greater_than: 0)
    |> validate_number(:quantity, greater_than: 0)
    |> foreign_key_constraint(:barter_id)
    |> foreign_key_constraint(:item_id)
  end
end
