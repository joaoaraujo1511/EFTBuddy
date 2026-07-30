defmodule EftBuddy.Repo.Migrations.CreateItemsCrafts do
  use Ecto.Migration

  def change do
    create table(:items_crafts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:external_id, :string, null: false)
      add(:duration, :integer, null: false)

      # FK into the existing hideout module. Crafts are produced at
      # a specific (station, level) pair so we just point at the
      # already-synced station_level row instead of duplicating
      # station/level columns.
      add(
        :station_level_id,
        references(:hideout_station_levels, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:task_unlock_id, references(:tasks, type: :binary_id, on_delete: :nilify_all))

      timestamps()
    end

    create(unique_index(:items_crafts, [:external_id]))
    create(index(:items_crafts, [:station_level_id]))
    create(index(:items_crafts, [:task_unlock_id]))
  end
end
