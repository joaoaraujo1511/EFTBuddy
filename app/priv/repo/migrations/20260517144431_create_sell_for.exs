defmodule EftBuddy.Repo.Migrations.CreateSellFor do
  use Ecto.Migration

  def change do
    create table(:sell_for, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :price, :integer, null: false
      add :price_rub, :integer
      add :currency, :string, null: false
      add :item_id, references(:items, type: :binary_id)
      add :vendor_id, references(:vendors, type: :binary_id)

      timestamps()
    end
  end
end
