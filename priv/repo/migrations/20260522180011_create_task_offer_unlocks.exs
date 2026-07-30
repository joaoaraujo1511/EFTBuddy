defmodule EftBuddy.Repo.Migrations.CreateTaskOfferUnlocks do
  use Ecto.Migration

  def change do
    # Tasks that unlock a specific *offer* — a trader (at a given
    # loyalty level) starts selling a particular item.
    create table(:task_offer_unlocks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :trader_id,
          references(:traders, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_id,
          references(:items, type: :binary_id, on_delete: :delete_all),
          null: false

      add :level, :integer, null: false
      add :reward_phase, :string, null: false

      timestamps()
    end

    create index(:task_offer_unlocks, [:task_id])
    create index(:task_offer_unlocks, [:trader_id])
    create index(:task_offer_unlocks, [:item_id])

    create unique_index(:task_offer_unlocks, [:task_id, :trader_id, :item_id, :reward_phase],
             name: :task_offer_unlocks_task_trader_item_phase_index
           )
  end
end
