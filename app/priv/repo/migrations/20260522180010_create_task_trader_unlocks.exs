defmodule EftBuddy.Repo.Migrations.CreateTaskTraderUnlocks do
  use Ecto.Migration

  def change do
    # Tasks that *unlock* a trader entirely (e.g. Ref, Lightkeeper).
    create table(:task_trader_unlocks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trader_id,
          references(:traders, type: :binary_id, on_delete: :delete_all),
          null: false

      add :reward_phase, :string, null: false

      timestamps()
    end

    create index(:task_trader_unlocks, [:task_id])
    create index(:task_trader_unlocks, [:trader_id])

    create unique_index(:task_trader_unlocks, [:task_id, :trader_id, :reward_phase],
             name: :task_trader_unlocks_task_trader_phase_index
           )
  end
end
