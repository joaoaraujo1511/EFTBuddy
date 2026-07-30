defmodule EftBuddy.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  @moduledoc """
  Creates the `events` + `event_quests` tables that back the Events tab,
  populated by the scheduled `EftBuddy.Events.Sync` (it scrapes the EFT
  Fandom "Events" page and each event quest's own wiki page).

  Mirrors the wiki-scrape table conventions (`wiki_quests` /
  `wiki_chapters`): cheap, frequently-queried fields are promoted to
  columns; the heavy parse-on-demand payload lives in a `content` JSONB
  blob projected by `EftBuddy.Wiki.Projection` only when a quest is
  expanded.

  ## `events`

    * `normalized_name` — the slug the app keys on, derived from the full
      `Name (date)` heading so recurring events (e.g. two "Bonus XP
      weekend" entries) stay distinct.
    * `name` / `event_date` — display name and the raw date string from
      the heading (`"25 June 2026"`).
    * `started_on` — parsed start date, for "most recent first" sorting
      (NULL when the heading date can't be parsed; those sort last).
    * `status` — `"active"` for events above the wiki's "past events"
      divider, `"past"` below it.
    * `position` — the event's order on the wiki page (0-based, newest
      first), the stable sort fallback when `started_on` is NULL.
    * `banner_url` — resolved Fandom CDN url of the event banner image.
    * `description` — the `{{quote}}` lore blurb (NULL when absent).
    * `content` — the full manifest (gameplay-changes list, banner meta,
      availability note, quest refs, raw section text).

  ## `event_quests`

  One row per (event, quest) pairing — a quest added by two different
  events gets a row under each. `content` is the same scraped quest
  manifest `wiki_quests.content` holds, so `EftBuddy.Wiki.Projection`
  renders an event quest's objectives/guide identically to the Tasks
  tab. `task_id` is a best-effort FK to a tarkov.dev task (almost always
  NULL — event quests are wiki-only).
  """

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :normalized_name, :string, null: false
      add :name, :string, null: false
      add :event_date, :string
      add :started_on, :date
      add :status, :string, null: false, default: "past"
      add :position, :integer, null: false, default: 0
      add :banner_url, :string
      add :description, :text
      add :content, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:events, [:normalized_name])
    # The index page lists events newest-first; the sort key is
    # (started_on desc, position asc), so index both.
    create index(:events, [:started_on])
    create index(:events, [:position])

    create table(:event_quests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :event_id,
          references(:events, type: :binary_id, on_delete: :delete_all),
          null: false

      add :normalized_name, :string, null: false
      add :name, :string, null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
      add :position, :integer, null: false, default: 0
      add :content, :map, null: false, default: %{}

      timestamps()
    end

    # A quest appears at most once per event.
    create unique_index(:event_quests, [:event_id, :normalized_name])
    # The WikiSync blacklist query is `SELECT DISTINCT normalized_name`,
    # and the Events context joins quests back to their event — index both.
    create index(:event_quests, [:normalized_name])
    create index(:event_quests, [:task_id])
  end
end
