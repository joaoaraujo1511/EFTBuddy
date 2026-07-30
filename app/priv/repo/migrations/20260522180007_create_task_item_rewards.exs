defmodule EftBuddy.Repo.Migrations.CreateTaskItemRewards do
  use Ecto.Migration

  def change do
    create table(:task_item_rewards, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_id,
          references(:items, type: :binary_id, on_delete: :delete_all),
          null: false

      add :quantity, :integer, null: false

      # `:start` for `startRewards` (given when accepting the quest);
      # `:finish` for `finishRewards` (given on turn-in).
      add :reward_phase, :string, null: false

      timestamps()
    end

    create index(:task_item_rewards, [:task_id])
    create index(:task_item_rewards, [:item_id])
    create index(:task_item_rewards, [:task_id, :reward_phase])

    create unique_index(:task_item_rewards, [:task_id, :item_id, :reward_phase],
             name: :task_item_rewards_task_item_phase_index
           )
  end
end
