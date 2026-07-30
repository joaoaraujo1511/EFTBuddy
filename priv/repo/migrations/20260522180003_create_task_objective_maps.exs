defmodule EftBuddy.Repo.Migrations.CreateTaskObjectiveMaps do
  use Ecto.Migration

  def change do
    create table(:task_objective_maps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :objective_id,
          references(:task_objectives, type: :binary_id, on_delete: :delete_all),
          null: false

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:task_objective_maps, [:objective_id])
    create index(:task_objective_maps, [:map_id])
    create unique_index(:task_objective_maps, [:objective_id, :map_id])
  end
end
