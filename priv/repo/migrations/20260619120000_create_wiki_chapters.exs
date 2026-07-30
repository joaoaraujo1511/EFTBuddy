defmodule EftBuddy.Repo.Migrations.CreateWikiChapters do
  use Ecto.Migration

  @moduledoc """
  Moves the storyline-chapter wiki data out of committed JSON manifests
  (`priv/static/storyline-dump/`) + a boot-time ETS table and into the
  database, populated by the scheduled `EftBuddy.Chapters.Sync`.

  Storyline counterpart to `wiki_quests` (see CreateWikiQuests). The two
  differ in one structural way: chapters are wiki-only editorial pages
  with NO tarkov.dev task behind them, so — unlike `wiki_quests` — there
  is no `task_id` FK, no `wip` flag, and no per-quest denormalised
  filter columns. Cross-links from a chapter to the real tasks it
  mentions are resolved at read time from the manifest's `related_links`,
  so they need no column either.

  Cheap keying/listing fields are columns:

    * `normalized_name` — the slug the app keys on (e.g. "boreas"). Also
      how the curated narrative order and the "endings" page are
      identified by `EftBuddy.Chapters`.
    * `chapter_name` — the cleaned display title.

  The heavy, parse-on-demand walkthrough (sections + raw wikitext) lives
  in the `content` JSONB column; `EftBuddy.Chapters.Projection` turns it
  into the render-ready content_sections / toc / items / banner maps only
  when a chapter is requested.
  """

  def change do
    create table(:wiki_chapters, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :normalized_name, :string, null: false
      add :chapter_name, :string, null: false
      add :content, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:wiki_chapters, [:normalized_name])
  end
end
