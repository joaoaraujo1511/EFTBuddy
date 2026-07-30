defmodule EftBuddy.Repo.Migrations.AddIsQuestItemToItems do
  use Ecto.Migration

  @moduledoc """
  Adds an `is_quest_item` flag to `items`. The Tarkov.dev API
  exposes quest-exclusive items (Golden Zibbo lighter, Cult
  medallion, etc.) as a separate `QuestItem` GraphQL type, but
  they overlap with regular items in everything that matters
  for our UI (name, icon, description). Storing them alongside
  regular items lets the Tasks page render them as proper tiles
  with click-through to the Items page, and avoids a parallel
  schema we'd have to keep in sync.

  Quest-item rows have NULL price / category / background_color
  fields — they don't trade and have no tier color — but every
  query in EftBuddy.Items already handles those nulls (they
  inherit the same shape regular items have when an API field
  is missing).

  After applying, run `EftBuddy.Items.Sync.run/0` (or restart the
  app) to populate quest items via the new sync_quest_items step.
  """

  def change do
    alter table(:items) do
      add :is_quest_item, :boolean, null: false, default: false
    end

    # Tasks page filters / future Items page filters will hit this
    # with a `WHERE is_quest_item = TRUE` predicate; index the
    # truthy-narrow case with a partial index so we don't bloat
    # the regular-item lookup paths.
    create index(:items, [:is_quest_item], where: "is_quest_item = TRUE")
  end
end
