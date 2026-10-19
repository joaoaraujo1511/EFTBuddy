defmodule EftBuddy.Repo.Migrations.CreateWikiBlacklistedPages do
  use Ecto.Migration

  @moduledoc """
  The wiki revision at which each quest page was found to be blacklisted (a Ref
  quest, or `{{Historical content}}`).

  Blacklisted pages get no `wiki_quests` row, so they had no stored revision and
  read as "changed" on every run: the quest scrape fetched the lead section of
  all ~197 of them every six hours, about 400 requests per run, only to skip
  them again (audit finding N2). The verdict depends only on the page's own lead
  section, so it holds until the page is edited.
  """

  def change do
    create table(:wiki_blacklisted_pages) do
      add :wiki_title, :string, null: false
      add :revision_id, :bigint, null: false
      add :reason, :string, null: false

      timestamps()
    end

    create unique_index(:wiki_blacklisted_pages, [:wiki_title])
  end
end
