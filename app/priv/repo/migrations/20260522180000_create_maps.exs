defmodule EftBuddy.Repo.Migrations.CreateMaps do
  use Ecto.Migration

  def change do
    create table(:maps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :string, null: false
      add :name, :string, null: false
      add :normalized_name, :string, null: false

      timestamps()
    end

    create unique_index(:maps, [:external_id])
    create unique_index(:maps, [:normalized_name])
  end
end
