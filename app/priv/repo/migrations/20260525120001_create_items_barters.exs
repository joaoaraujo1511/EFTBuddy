defmodule EftBuddy.Repo.Migrations.CreateItemsBarters do
  use Ecto.Migration

  def change do
    create table(:items_barters, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:external_id, :string, null: false)
      add(:level, :integer, null: false)
      add(:buy_limit, :integer)

      add(:trader_id, references(:traders, type: :binary_id, on_delete: :restrict), null: false)

      # `:nilify_all`: a barter can outlive the task that originally
      # gated it (e.g. wipe-related task removals). Surface "no
      # unlock" rather than blowing up the row.
      add(:task_unlock_id, references(:tasks, type: :binary_id, on_delete: :nilify_all))

      timestamps()
    end

    create(unique_index(:items_barters, [:external_id]))
    create(index(:items_barters, [:trader_id]))
    create(index(:items_barters, [:task_unlock_id]))
  end
end
