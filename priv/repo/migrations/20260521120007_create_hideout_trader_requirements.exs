defmodule EftBuddy.Repo.Migrations.CreateHideoutTraderRequirements do
  use Ecto.Migration

  def change do
    create table(:hideout_trader_requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :required_level, :integer, null: false

      add :level_id,
          references(:hideout_station_levels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trader_id,
          references(:traders, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:hideout_trader_requirements, [:level_id])
    create index(:hideout_trader_requirements, [:trader_id])
    create unique_index(:hideout_trader_requirements, [:level_id, :trader_id])
  end
end
