defmodule EftBuddy.Repo.Migrations.CreateTaskObjectives do
  use Ecto.Migration

  def change do
    create table(:task_objectives, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :string, null: false

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      # The GraphQL union type — `TaskObjectiveItem`,
      # `TaskObjectiveExtract`, etc. Stored as a string so we can render
      # per-type in the UI without a join table per subtype.
      add :type, :string, null: false
      add :description, :text
      add :optional, :boolean, null: false, default: false

      # Subtype-specific fields (count, items, exitName, …) — JSONB so
      # we can grow without a migration per new field. The shape is
      # documented in the Sync module.
      add :payload, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:task_objectives, [:external_id])
    create index(:task_objectives, [:task_id])
    create index(:task_objectives, [:type])
  end
end
