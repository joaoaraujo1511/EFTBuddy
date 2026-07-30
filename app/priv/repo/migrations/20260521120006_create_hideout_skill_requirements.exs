defmodule EftBuddy.Repo.Migrations.CreateHideoutSkillRequirements do
  use Ecto.Migration

  def change do
    create table(:hideout_skill_requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :required_level, :integer, null: false

      add :level_id,
          references(:hideout_station_levels, type: :binary_id, on_delete: :delete_all),
          null: false

      add :skill_id,
          references(:skills, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:hideout_skill_requirements, [:level_id])
    create index(:hideout_skill_requirements, [:skill_id])
    create unique_index(:hideout_skill_requirements, [:level_id, :skill_id])
  end
end
