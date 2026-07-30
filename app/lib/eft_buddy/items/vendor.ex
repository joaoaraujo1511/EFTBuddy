defmodule EftBuddy.Items.Vendor do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vendors" do
    field :name, :string
    field :normalized_name, :string

    has_many :sell_for, EftBuddy.Items.SellFor, foreign_key: :vendor_id
    has_many :buy_for, EftBuddy.Items.BuyFor, foreign_key: :vendor_id

    timestamps()
  end

  @doc """
  Creates a changeset for vendor creation.
  """
  def changeset(vendor, attrs) do
    vendor
    |> cast(attrs, [:name, :normalized_name])
    |> validate_required([:name])
  end

  @doc """
  Creates a changeset for updating vendors.
  """
  def update_changeset(vendor, attrs) do
    vendor
    |> cast(attrs, [:name, :normalized_name])
  end
end
