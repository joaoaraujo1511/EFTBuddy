defmodule EftBuddy.Repo.Migrations.CreateTaskTraderStandingRewards do
  use Ecto.Migration

  def change do
    create table(:task_trader_standing_rewards, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trader_id,
          references(:traders, type: :binary_id, on_delete: :delete_all),
          null: false

      # Standing is fractional (e.g. +0.02) — float matches the API.
      add :standing, :float, null: false
      add :reward_phase, :string, null: false

      timestamps()
    end

    create index(:task_trader_standing_rewards, [:task_id])
    create index(:task_trader_standing_rewards, [:trader_id])

    create unique_index(:task_trader_standing_rewards, [:task_id, :trader_id, :reward_phase],
             name: :task_trader_standing_rewards_task_trader_phase_index
           )
  end
end
