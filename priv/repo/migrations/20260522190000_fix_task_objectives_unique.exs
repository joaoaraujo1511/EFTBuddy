defmodule EftBuddy.Repo.Migrations.FixTaskObjectivesUnique do
  use Ecto.Migration

  # The Tarkov.dev API returns the same objective `id` for different
  # tasks (objective IDs are task-scoped, not global). Replace the
  # global unique index on external_id with a composite unique index
  # on (task_id, external_id) so shared IDs across tasks coexist
  # while we still catch real duplicates within a single task.
  def change do
    drop unique_index(:task_objectives, [:external_id])

    create unique_index(:task_objectives, [:task_id, :external_id],
             name: :task_objectives_task_external_id_index
           )
  end
end
