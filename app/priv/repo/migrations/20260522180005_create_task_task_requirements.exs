defmodule EftBuddy.Repo.Migrations.CreateTaskTaskRequirements do
  use Ecto.Migration

  def change do
    create table(:task_task_requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The task that has the prerequisite ("to start X you must have…").
      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      # The prerequisite task ("…task Y in `status`").
      add :prerequisite_task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      # Statuses the prerequisite must satisfy. Tarkov.dev returns this
      # as a list (e.g. `["complete"]`, `["active"]`, `["failed"]`).
      add :status, {:array, :string}, null: false, default: []

      timestamps()
    end

    create index(:task_task_requirements, [:task_id])
    create index(:task_task_requirements, [:prerequisite_task_id])

    create unique_index(:task_task_requirements, [:task_id, :prerequisite_task_id],
             name: :task_task_reqs_task_prereq_index
           )
  end
end
