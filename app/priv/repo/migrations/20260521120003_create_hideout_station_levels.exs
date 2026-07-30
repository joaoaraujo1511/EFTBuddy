defmodule EftBuddy.Repo.Migrations.CreateHideoutStationLevels do
  use Ecto.Migration

  def change do
    create table(:hideout_station_levels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :level, :integer, null: false

      add :station_id,
          references(:hideout_stations, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create unique_index(:hideout_station_levels, [:station_id, :level])
    create index(:hideout_station_levels, [:station_id])
  end
end
