defmodule EftBuddy.Items.BuyFor do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "buy_for" do
    field :price, :integer
    field :price_rub, :integer
    field :currency, :string
    field :game_mode, :string, default: "regular"

    belongs_to :item, EftBuddy.Items.Item
    belongs_to :vendor, EftBuddy.Items.Vendor

    timestamps()
  end

  @doc """
  Creates a changeset for buy_for creation.
  """
  def changeset(buy_for, attrs) do
    buy_for
    |> cast(attrs, [:price, :price_rub, :currency, :game_mode, :item_id, :vendor_id])
    |> validate_required([:price, :currency, :item_id, :vendor_id])
    |> foreign_key_constraint(:item_id)
    |> foreign_key_constraint(:vendor_id)
  end
end
