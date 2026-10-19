defmodule EftBuddy.Repo.Migrations.DropTaskObjectivesPayloadGinIndex do
  use Ecto.Migration

  @moduledoc """
  Drops the GIN index on `task_objectives.payload` (audit L9).

  It was added for `payload @> ...` containment and `payload ? 'questItem'`
  queries. None exist: every query on the column extracts with `->`, `->>`,
  `jsonb_typeof` or `jsonb_array_elements_text`, and a GIN index serves none of
  those. So it never answered a query, and it cost a write on every row the
  Tasks sync rewrites.
  """

  def up do
    drop_if_exists index(:task_objectives, [:payload], name: :task_objectives_payload_gin_index)
  end

  def down do
    create index(:task_objectives, [:payload],
             using: "GIN",
             name: :task_objectives_payload_gin_index
           )
  end
end
