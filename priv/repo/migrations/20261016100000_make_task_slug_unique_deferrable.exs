defmodule EftBuddy.Repo.Migrations.MakeTaskSlugUniqueDeferrable do
  @moduledoc """
  Task slugs stay unique per game mode, but the check moves to commit time.

  `Tasks.Sync` upserts on `(external_id, game_mode)` and rewrites
  `normalized_name`. When tarkov.dev renames tasks so that one task takes a
  name another still holds (the Punisher quests swapped names), the plain
  unique index rejected the intermediate row with 23505 and the whole run for
  that mode rolled back, every run, until upstream renamed again.

  A constraint can be DEFERRABLE INITIALLY DEFERRED and an index cannot, which
  is why this is `execute/2` rather than `unique_index/2`. Postgres refuses ON
  CONFLICT on a deferrable constraint, so nothing may use it as an upsert
  arbiter; nothing does (the task upsert's arbiter is the id).
  """
  use Ecto.Migration

  def up do
    drop unique_index(:tasks, [:normalized_name, :game_mode])

    execute """
    ALTER TABLE tasks
      ADD CONSTRAINT tasks_normalized_name_game_mode_index
      UNIQUE (normalized_name, game_mode) DEFERRABLE INITIALLY DEFERRED
    """
  end

  def down do
    execute "ALTER TABLE tasks DROP CONSTRAINT tasks_normalized_name_game_mode_index"
    create unique_index(:tasks, [:normalized_name, :game_mode])
  end
end
