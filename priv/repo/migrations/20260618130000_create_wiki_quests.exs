defmodule EftBuddy.Repo.Migrations.CreateWikiQuests do
  use Ecto.Migration

  @moduledoc """
  Moves the per-quest wiki walkthrough data out of committed JSON
  manifests (`priv/static/wiki-dump/`) + a boot-time ETS table and into
  the database, populated by the scheduled `EftBuddy.Wiki.Sync`.

  Cheap, frequently-queried fields (the Tasks list only needs these) are
  promoted to columns:

    * `normalized_name` — the slug the app keys on. For a quest the wiki
      sync could match to an API task this is the task's `normalized_name`
      (so it joins/dedups cleanly); for a wiki-only WIP quest it's the
      wiki-derived slug.
    * `task_id` — FK to the matched task (NULL for WIP quests).
    * `wip` — true when the wiki has the quest but the API doesn't (yet).
    * `given_by` — infobox quest-giver, for the trader filter.
    * `karma_kind` / `karma_value` — parsed scav-karma threshold
      (`"gte"`/`"lte"` + n), so the karma filter is a cheap query rather
      than a fold over every quest's parsed content.

  The heavy, parse-on-demand walkthrough (sections + wikitext) lives in
  the `content` JSONB column; `EftBuddy.Wiki.Projection` turns it into
  the render-ready guide/objective/banner maps only when a quest is
  expanded.
  """

  def change do
    create table(:wiki_quests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :normalized_name, :string, null: false
      add :name, :string, null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :wip, :boolean, null: false, default: false
      add :given_by, :string
      add :karma_kind, :string
      add :karma_value, :integer
      add :content, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:wiki_quests, [:normalized_name])
    create index(:wiki_quests, [:task_id])
    # Partial index for the WIP-merge query (`where wip = true`).
    create index(:wiki_quests, [:wip], where: "wip = TRUE")
    # Partial index for the karma-requirements query.
    create index(:wiki_quests, [:karma_kind], where: "karma_kind IS NOT NULL")
  end
end
