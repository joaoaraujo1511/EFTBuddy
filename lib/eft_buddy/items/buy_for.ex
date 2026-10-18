defmodule EftBuddy.Items.BuyFor do
  use Ecto.Schema

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
end
