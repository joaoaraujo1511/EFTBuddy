defmodule EftBuddy.Repo.Migrations.AddPositionToTaskObjectives do
  use Ecto.Migration

  @moduledoc """
  Adds a `position` column to `task_objectives` so the LiveView can
  render objectives in the order the Tarkov.dev API returned them.

  Until now we sorted by `inserted_at` at render time, but the Tasks
  sync writes every objective with the same second-precision
  timestamp (rows are bulk-built in tight `Enum.reduce` loops), and
  the reduce itself reverses the API order via `[row | rows]`. So
  the displayed order was effectively random within a quest — the
  bug surfaced clearly on Golden Swag, where "Stash the Zibbo"
  rendered above "Find the Zibbo".

  The column is nullable for backward compatibility: existing rows
  start with NULL and the LiveView's order_by puts NULLs last, so
  unmigrated objectives still render (just in a deterministic
  fallback order). Re-running `EftBuddy.Tasks.Sync.run/0` after this
  migration populates positions.
  """

  def change do
    alter table(:task_objectives) do
      add :position, :integer, null: true
    end

    # Lookup-by-position-within-task is the dominant access pattern
    # at render time; index it.
    create index(:task_objectives, [:task_id, :position])
  end
end
