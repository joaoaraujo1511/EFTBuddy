defmodule EftBuddy.Items.Vendor do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vendors" do
    field :name, :string
    field :normalized_name, :string

    has_many :buy_for, EftBuddy.Items.BuyFor, foreign_key: :vendor_id

    timestamps()
  end
end
