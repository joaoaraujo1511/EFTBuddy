defmodule EftBuddy.Wiki.SyncConditionalFetchTest do
  @moduledoc """
  Skipping unedited wiki pages, and the one way it could go catastrophically
  wrong.

  `prune/1` deletes every `wiki_quests` row whose slug is absent from the
  keep-set. A page skipped because nothing changed looks exactly like a page that
  vanished from the wiki, so building the keep-set from the pages that were
  SCRAPED rather than the pages that were ENUMERATED would delete most of the
  table on the first incremental run — silently, and only once, because the next
  run would rescrape everything and put it back.

  That is the failure these tests exist for. The partition rules are here too,
  because "unknown" has to mean "scrape it" in every direction.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Wiki.QuestPage
  alias EftBuddy.Wiki.Sync

  defp quest(slug, title \\ nil) do
    %{normalized_name: slug, wiki_title: title || slug, name: slug, wip: true, id: nil}
  end

  defp stored(slug, revision_id) do
    Repo.insert!(%QuestPage{
      normalized_name: slug,
      name: slug,
      wip: true,
      revision_id: revision_id,
      content: %{}
    })
  end

  describe "partition_by_revision/2" do
    test "an unedited page is skipped" do
      stored("debut", 100)

      {scrape, unchanged} = Sync.partition_by_revision([quest("debut")], %{"debut" => 100})

      assert scrape == []
      assert [%{normalized_name: "debut"}] = unchanged
    end

    test "an edited page is scraped" do
      stored("debut", 100)

      {scrape, unchanged} = Sync.partition_by_revision([quest("debut")], %{"debut" => 101})

      assert [%{normalized_name: "debut"}] = scrape
      assert unchanged == []
    end

    test "a page with no stored row is scraped" do
      # Nothing to compare against — every page on the first run after this
      # shipped, since the migration deliberately backfills nothing.
      {scrape, unchanged} = Sync.partition_by_revision([quest("debut")], %{"debut" => 100})

      assert [%{normalized_name: "debut"}] = scrape
      assert unchanged == []
    end

    test "a page with a stored row but no stored revision is scraped" do
      stored("debut", nil)

      {scrape, _} = Sync.partition_by_revision([quest("debut")], %{"debut" => 100})

      assert [%{normalized_name: "debut"}] = scrape
    end

    test "a page the revision probe could not answer for is scraped" do
      # A failed batch yields no revisions, which must degrade to the behaviour
      # before conditional fetching existed rather than to skipping everything.
      stored("debut", 100)

      {scrape, _} = Sync.partition_by_revision([quest("debut")], %{})

      assert [%{normalized_name: "debut"}] = scrape
    end

    test "the probe is keyed on wiki title, not slug" do
      # Titles are normalised and redirected by the API. If the answers were not
      # mapped back to the titles we asked about, every redirected page would
      # read as unknown and be scraped on every single run — the optimisation
      # would quietly do nothing.
      stored("the-punisher-part-1", 100)
      q = quest("the-punisher-part-1", "The Punisher - Part 1")

      {scrape, unchanged} =
        Sync.partition_by_revision([q], %{"The Punisher - Part 1" => 100})

      assert scrape == []
      assert length(unchanged) == 1
    end
  end

  describe "the keep-set and the prune" do
    test "a row whose slug is in the keep-set survives" do
      stored("kept", 1)
      stored("gone", 1)

      assert Sync.prune(["kept"]) == 1
      assert Repo.aggregate(QuestPage, :count, :id) == 1
      assert Repo.get_by!(QuestPage, normalized_name: "kept")
    end

    test "an empty keep-set deletes nothing rather than the whole table" do
      # Guards the pathological "everything got blacklisted" case from
      # `NOT IN ()`-ing the table away.
      stored("a", 1)
      stored("b", 1)

      assert Sync.prune([]) == 0
      assert Repo.aggregate(QuestPage, :count, :id) == 2
    end

    test "unchanged pages must be in the keep-set the scrape builds" do
      # THE SHARP EDGE. This asserts the shape rather than running the scrape,
      # because `scrape_and_upsert/2` fetches from the network — but the shape is
      # the whole bug: build the keep-set from what was scraped and every skipped
      # page is deleted.
      all = [quest("scraped"), quest("unchanged")]
      stored("scraped", 1)
      stored("unchanged", 2)

      {scrape, unchanged} =
        Sync.partition_by_revision(all, %{"scraped" => 99, "unchanged" => 2})

      assert length(scrape) == 1
      assert length(unchanged) == 1

      # What the sync does: keep-set from ALL enumerated quests, not from
      # `scrape`. Pruning on the scraped set alone would take "unchanged" out.
      keep_from_all = Enum.map(all, & &1.normalized_name)
      keep_from_scraped_only = Enum.map(scrape, & &1.normalized_name)

      assert Sync.prune(keep_from_scraped_only) == 1,
             "pruning on the scraped set alone deletes the skipped page — this is the bug"

      # Put it back and prove the real keep-set preserves it.
      stored("unchanged", 2)
      assert Sync.prune(keep_from_all) == 0
      assert Repo.aggregate(QuestPage, :count, :id) == 2
    end
  end
end
