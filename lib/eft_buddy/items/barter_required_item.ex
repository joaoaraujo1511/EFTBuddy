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

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_barter_required_items" do
    field(:count, :decimal)
    field(:quantity, :decimal)
    field(:attributes, :map, default: %{})

    belongs_to(:barter, EftBuddy.Items.Barter)
    belongs_to(:item, EftBuddy.Items.Item)

    timestamps()
  end
end
