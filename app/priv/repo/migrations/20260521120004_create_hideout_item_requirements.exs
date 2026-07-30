defmodule EftBuddy.Repo.Migrations.CreateHideoutItemRequirements do
  use Ecto.Migration

  def change do
    create table(:hideout_item_requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :quantity, :integer, null: false

      add :level_id,
          references(:hideout_station_levels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_id,
          references(:items, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:hideout_item_requirements, [:level_id])
    create index(:hideout_item_requirements, [:item_id])
    create unique_index(:hideout_item_requirements, [:level_id, :item_id])
  end
end
