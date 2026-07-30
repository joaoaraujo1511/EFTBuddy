defmodule EftBuddy.Repo.Migrations.CreateTaskUnlocks do
  use Ecto.Migration

  def change do
    # Computed reverse index of `task_task_requirements` (status =
    # "complete"). Lets us answer "what does completing X unlock?"
    # without scanning the requirements table at read time.
    # Rebuilt from scratch at the end of every sync.
    create table(:task_unlocks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :prerequisite_task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :unlocked_task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:task_unlocks, [:prerequisite_task_id])
    create index(:task_unlocks, [:unlocked_task_id])

    create unique_index(:task_unlocks, [:prerequisite_task_id, :unlocked_task_id],
             name: :task_unlocks_prereq_unlocked_index
           )
  end
end
