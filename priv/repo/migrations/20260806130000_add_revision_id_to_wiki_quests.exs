defmodule EftBuddy.Repo.Migrations.AddRevisionIdToWikiQuests do
  @moduledoc """
  Record the wiki revision each stored manifest was scraped from, so a scrape can
  skip pages that have not been edited.

  The quest scrape moved from daily to every six hours, which is four times the
  traffic at a third party that already rate-limits with 503s — for
  human-authored walkthrough prose that does not change four times a day. One
  batched `prop=revisions` query per fifty pages tells us which pages moved;
  everything else costs nothing.

  Deliberately left NULL on the backfill rather than guessed. A null means "we do
  not know what this row was scraped from", and the only safe reading of that is
  to scrape it — so the first run after this migration is a full one, and every
  run after it is incremental.
  """
  use Ecto.Migration

  def change do
    alter table(:wiki_quests) do
      add :revision_id, :bigint
    end
  end
end
