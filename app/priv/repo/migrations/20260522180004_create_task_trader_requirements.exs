defmodule EftBuddy.Repo.Migrations.CreateTaskTraderRequirements do
  use Ecto.Migration

  def change do
    create table(:task_trader_requirements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trader_id,
          references(:traders, type: :binary_id, on_delete: :delete_all),
          null: false

      # API fields — kept verbatim so the UI can show the full
      # condition ("Loyalty level >= 2", "Standing >= 0.20", …).
      add :requirement_type, :string
      add :compare_method, :string
      add :value, :integer

      timestamps()
    end

    create index(:task_trader_requirements, [:task_id])
    create index(:task_trader_requirements, [:trader_id])

    create unique_index(:task_trader_requirements, [:task_id, :trader_id, :requirement_type],
             name: :task_trader_reqs_task_trader_type_index
           )
  end
end
