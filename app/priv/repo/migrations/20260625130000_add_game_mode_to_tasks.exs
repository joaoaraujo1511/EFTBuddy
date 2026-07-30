defmodule EftBuddy.Repo.Migrations.AddGameModeToTasks do
  use Ecto.Migration

  @moduledoc """
  Tasks genuinely diverge between PVP (`regular`) and PVE: the two
  modes have different task *sets* (some quests are mode-exclusive)
  and different requirements (min player level, prerequisite chains,
  kappa flags). So a task is now identified by `(external_id,
  game_mode)` rather than `external_id` alone — the same tarkov.dev
  task id can appear once per mode with different data.

  All task *child* rows (objectives, requirements, rewards, unlocks)
  are FK'd to the task UUID, so they inherit their mode through the
  parent and need no column of their own.

  Existing rows are backfilled to `"regular"` via the column default.
  """

  def change do
    alter table(:tasks) do
      add :game_mode, :string, null: false, default: "regular"
    end

    # The old single-column uniques assumed one row per task id /
    # slug. With two modes the same id/slug legitimately appears
    # twice, so the uniqueness key gains `game_mode`.
    drop unique_index(:tasks, [:external_id])
    drop unique_index(:tasks, [:normalized_name])

    create unique_index(:tasks, [:external_id, :game_mode])
    create unique_index(:tasks, [:normalized_name, :game_mode])
    create index(:tasks, [:game_mode])
  end
end
