defmodule EftBuddy.Repo.Migrations.AddRevisionIdToEventQuests do
  @moduledoc """
  The wiki revision each event quest's walkthrough was scraped at (audit M22).

  The events scrape re-fetched all ~250 event quest pages every twelve hours,
  14-16 minutes and about 1,700 requests per run against a wiki that
  rate-limits. With the revision stored it probes revisions in a few batched
  requests and only scrapes pages edited since, as the quest scrape does.

  Starts NULL, which means "scrape it", so the first run after deploy is a full
  scrape that fills the column in.
  """
  use Ecto.Migration

  def change do
    alter table(:event_quests) do
      add :revision_id, :bigint
    end
  end
end
