defmodule EftBuddy.Items.SellFor do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "sell_for" do
    field :price, :integer
    field :price_rub, :integer
    field :currency, :string
    field :game_mode, :string, default: "regular"

    belongs_to :item, EftBuddy.Items.Item
    belongs_to :vendor, EftBuddy.Items.Vendor

    timestamps()
  end

  @doc """
  Creates a changeset for sell_for creation.
  """
  def changeset(sell_for, attrs) do
    sell_for
    |> cast(attrs, [:price, :price_rub, :currency, :game_mode, :item_id, :vendor_id])
    |> validate_required([:price, :currency, :item_id, :vendor_id])
    |> foreign_key_constraint(:item_id)
    |> foreign_key_constraint(:vendor_id)
  end
end
