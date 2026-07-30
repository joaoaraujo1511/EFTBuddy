defmodule EftBuddy.Repo.Migrations.AddGinIndexToTaskObjectivesPayload do
  use Ecto.Migration

  @moduledoc """
  Adds a GIN index on `task_objectives.payload` (jsonb).

  The Items context runs containment / key-existence queries against this
  column on hot paths:

    * `EftBuddy.Items` "Quest" scope and the per-item "needed by quests"
      panel use `payload @> ...` containment and `payload ? 'questItem'`
      style predicates;
    * these run on every item-detail expand and every Quest-scope page
      load.

  Without an index those are sequential scans over the whole objectives
  table. `jsonb_path_ops` keeps the index compact and is the right
  operator class for `@>` containment (the dominant query shape). Created
  CONCURRENTLY-friendly is unnecessary here since the table is small and
  rebuilt by the Tasks sync, so a plain `create index` is fine.
  """

  def change do
    create index(:task_objectives, [:payload],
             using: "GIN",
             name: :task_objectives_payload_gin_index
           )
  end
end
