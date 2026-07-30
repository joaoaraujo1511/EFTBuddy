defmodule EftBuddy.Repo.Migrations.CreateVendors do
  use Ecto.Migration

  def change do
    create table(:vendors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :normalized_name, :string

      timestamps()
    end

    create unique_index(:vendors, [:name])
  end
end
