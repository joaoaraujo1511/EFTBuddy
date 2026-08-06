defmodule EftBuddy.Repo.Migrations.AddBannerUrlToWikiQuests do
  @moduledoc """
  Promote the wiki quest banner out of the `content` JSONB and into a column.

  Wiki-only (WIP) quests rendered their banner inside the expandable detail panel
  while every API-backed quest rendered it as a thumbnail on the collapsed row —
  so the two sources disagreed about where a banner belongs, and WIP rows showed
  an empty placeholder in the list.

  The banner was already scraped; it just was not reachable at list time.
  `Wiki.all_quests/0` deliberately selects four cheap columns and never touches
  `content`, because projecting every wiki page at mount to find a thumbnail is
  exactly the cost that read is shaped to avoid. A column makes the URL cost one
  more field on a query that already runs.

  Backfilled from the manifest rather than left null, so the fix does not wait
  for the next scrape.
  """
  use Ecto.Migration

  def up do
    alter table(:wiki_quests) do
      add :banner_url, :string
    end

    # The banner is the file flagged `banner: true` in the lead section's file
    # list — the same shape `EftBuddy.Wiki.Projection.extract_banner/1` reads.
    execute("""
    UPDATE wiki_quests q
    SET banner_url = f.url
    FROM (
      SELECT
        w.id,
        (file ->> 'url') AS url
      FROM wiki_quests w
      CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(w.content -> 'sections', '[]'::jsonb)
      ) AS section
      CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(section -> 'files', '[]'::jsonb)
      ) AS file
      WHERE (file ->> 'banner') = 'true'
        AND COALESCE(file ->> 'url', '') <> ''
    ) AS f
    WHERE q.id = f.id
    """)
  end

  def down do
    alter table(:wiki_quests) do
      remove :banner_url
    end
  end
end
