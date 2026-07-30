defmodule EftBuddy.Repo.Migrations.CreateHideoutStationLevelRequirements do
  use Ecto.Migration

  def change do
    create table(:hideout_station_level_requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :required_level, :integer, null: false

      add :level_id,
          references(:hideout_station_levels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :required_station_id,
          references(:hideout_stations, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:hideout_station_level_requirements, [:level_id])
    create index(:hideout_station_level_requirements, [:required_station_id])

    create unique_index(:hideout_station_level_requirements, [:level_id, :required_station_id],
             name: :hideout_station_level_reqs_level_required_station_index
           )
  end
end
