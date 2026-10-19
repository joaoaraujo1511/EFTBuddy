defmodule EftBuddy.Wiki.ScrapeOutcomesTest do
  @moduledoc """
  The three Fandom scrapes run end to end against a fake wiki
  (`EftBuddy.WikiStub`), with failures injected where they happen in production.

  Each test pins an audit finding: a page stored as current after a failed
  section (H11), a short category listing treated as complete (H12), a run
  reporting ok whatever failed (H14), an API error read as an empty success
  (M19), a failed quest page wiping its walkthrough (M21), and one bad event row
  aborting the run (M25).
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog
  import EftBuddy.Fixtures, only: [task: 1]

  alias EftBuddy.Chapters.Sync, as: ChaptersSync
  alias EftBuddy.Events.{Event, EventQuest}
  alias EftBuddy.Events.Sync, as: EventsSync
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.Wiki.{Api, FileLicense, QuestPage}
  alias EftBuddy.Wiki.Sync, as: WikiSync
  alias EftBuddy.WikiStub

  setup do
    Reporter.reset_status()
    FileLicense.clear_cache()

    on_exit(fn ->
      Reporter.reset_status()
      FileLicense.clear_cache()
    end)

    # The quest scrape skips entirely while the tasks table is empty.
    task(%{name: "Some Real Task", normalized_name: "some-real-task"})
    :ok
  end

  defp quest_wiki(titles, opts \\ []) do
    Map.merge(
      %{
        categories: %{"Category:Quests" => titles},
        pages:
          Map.new(titles, fn t ->
            {t, WikiStub.page(revid: 10, sections: [{"Guide", "Do the thing."}])}
          end)
      },
      Map.new(opts)
    )
  end

  defp run_quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  defp row(slug), do: Repo.get_by(QuestPage, normalized_name: slug)

  describe "the API client" do
    test "an HTTP 200 carrying an API error is an error, not an empty success (M19)" do
      WikiStub.serve(%{pages: %{}, api_error: fn _ -> true end})

      assert {:error, {:api, "ratelimited", "slow down"}} = Api.section_list("Anything")
    end

    test "a missing page is an error" do
      WikiStub.serve(%{pages: %{}})

      assert {:error, {:api, "missingtitle", _}} = Api.section_list("Nope")
    end

    test "a category spanning several pages is listed whole" do
      WikiStub.serve(%{categories: %{"Category:Quests" => ~w(A B C D E)}, page_size: 2})

      assert Api.category_members("Category:Quests") == {:ok, ~w(A B C D E)}
    end

    test "a category whose later page fails is an error, not the first page alone (H12)" do
      WikiStub.serve(%{
        categories: %{"Category:Quests" => ~w(A B C D E)},
        page_size: 2,
        fail: &Map.has_key?(&1, "cmcontinue")
      })

      assert {:error, {:http, 503, _}} = Api.category_members("Category:Quests")
    end

    test "a licence lookup answered with an API error is not cached as 'no licence' (M19)" do
      WikiStub.serve(%{
        files: %{"File:Map.png" => %{page: "{{Copyright CC-BY-NC-SA 4.0}}"}},
        api_error: &(&1["rvprop"] == "content")
      })

      run_quietly(fn -> FileLicense.fetch(["File:Map.png"], Api.http_opts()) end)

      # Upstream recovers: the licence is found, because nothing was cached.
      WikiStub.serve(%{files: %{"File:Map.png" => %{page: "{{Copyright CC-BY-NC-SA 4.0}}"}}})

      {licenses, 0} = FileLicense.fetch(["File:Map.png"], Api.http_opts())
      assert licenses["File:Map.png"].label == "CC BY-NC-SA 4.0"
    end
  end

  describe "the quest scrape stamps a revision only on a complete page (H11)" do
    test "a page whose section failed is stored without one, then retried and stamped" do
      WikiStub.serve(quest_wiki(["Golden Swag"], fail: &(&1["section"] == "1")))

      assert {:ok, %{incomplete: 1}} = run_quietly(&WikiSync.do_run/0)
      assert row("golden-swag").revision_id == nil

      # Next run, upstream has recovered and the page has NOT been edited. It is
      # scraped anyway, because nothing claims it is current.
      WikiStub.serve(quest_wiki(["Golden Swag"]))

      assert {:ok, %{processed: 1, incomplete: 0}} = run_quietly(&WikiSync.do_run/0)
      assert row("golden-swag").revision_id == 10
      assert inspect(row("golden-swag").content) =~ "Do the thing."
    end

    test "a page whose contributor roster failed is not marked current either" do
      WikiStub.serve(quest_wiki(["Golden Swag"], fail: &(&1["prop"] == "contributors")))

      run_quietly(&WikiSync.do_run/0)

      assert row("golden-swag").revision_id == nil
    end

    test "a complete page is stamped and skipped next run" do
      WikiStub.serve(quest_wiki(["Golden Swag"]))
      run_quietly(&WikiSync.do_run/0)
      assert row("golden-swag").revision_id == 10

      assert {:ok, %{processed: 0, unchanged: 1}} = run_quietly(&WikiSync.do_run/0)
    end
  end

  describe "a quest scrape's outcome (H14)" do
    test "is an error when more than 10% of its pages failed" do
      titles = for i <- 1..10, do: "Quest #{i}"
      WikiStub.serve(quest_wiki(titles, fail: &(&1["page"] in ["Quest 1", "Quest 2"])))

      assert {:error, {:pages_failed, 2, 10, summary}} = run_quietly(&WikiSync.do_run/0)
      assert summary.processed == 8
      assert Reporter.status()["WikiSync"].outcome == :error
    end

    test "is ok with one failure in ten, which is retried next run" do
      titles = for i <- 1..10, do: "Quest #{i}"
      WikiStub.serve(quest_wiki(titles, fail: &(&1["page"] == "Quest 1")))

      assert {:ok, %{processed: 9, failed: 1}} = run_quietly(&WikiSync.do_run/0)
    end

    test "is an error, keeping every row, when the category cannot be listed whole (H12)" do
      titles = for i <- 1..6, do: "Quest #{i}"
      WikiStub.serve(quest_wiki(titles))
      run_quietly(&WikiSync.do_run/0)
      assert Repo.aggregate(QuestPage, :count) == 6

      WikiStub.serve(quest_wiki(titles, page_size: 2, fail: &Map.has_key?(&1, "cmcontinue")))

      assert {:error, {:enumeration_failed, _}} = run_quietly(&WikiSync.do_run/0)
      assert Repo.aggregate(QuestPage, :count) == 6
    end
  end

  describe "the events scrape" do
    @events_page """
    ==Wild Wild Woods (25 June 2026)==
    {{quote|A Scav mutiny.}}
    * Quest [[Wild Wild Woods]] has been added.
    ==Frost Bite (10 January 2026)==
    * Quest [[Cold Feet]] has been added.
    """

    defp events_wiki(opts \\ []) do
      Map.merge(
        %{
          pages: %{
            "Events" => WikiStub.page(full: Keyword.get(opts, :events_page, @events_page)),
            "Wild Wild Woods" => WikiStub.page(sections: [{"Guide", "Walk the woods."}]),
            "Cold Feet" => WikiStub.page(sections: [{"Guide", "Stay warm."}])
          }
        },
        Map.new(Keyword.delete(opts, :events_page))
      )
    end

    defp event_quest(slug), do: Repo.get_by!(EventQuest, normalized_name: slug)

    test "a quest page that fails keeps its stored walkthrough (M21)" do
      WikiStub.serve(events_wiki())
      assert {:ok, _} = run_quietly(&EventsSync.do_run/0)
      assert inspect(event_quest("cold-feet").content) =~ "Stay warm."

      WikiStub.serve(events_wiki(fail: &(&1["page"] == "Cold Feet")))
      run_quietly(&EventsSync.do_run/0)

      assert inspect(event_quest("cold-feet").content) =~ "Stay warm.",
             "a transient failure must not overwrite the walkthrough with %{}"
    end

    test "one event row that cannot be written does not abort the rest (M25)" do
      page = "==(25 June 2026)==\n* Quest [[Cold Feet]] has been added.\n" <> @events_page
      WikiStub.serve(events_wiki(events_page: page))

      assert {:ok, %{events: 3}} = run_quietly(&EventsSync.do_run/0)
      assert Repo.get_by(Event, normalized_name: "wild-wild-woods-25-june-2026")
      assert Repo.get_by(Event, normalized_name: "frost-bite-10-january-2026")
    end

    test "is an error when most of its quest pages failed (H14)" do
      WikiStub.serve(events_wiki(fail: &(&1["page"] in ["Cold Feet", "Wild Wild Woods"])))

      assert {:error, {:pages_failed, 2, 2, _}} = run_quietly(&EventsSync.do_run/0)
    end
  end

  describe "the chapters scrape" do
    test "a failed enumeration is a recorded failed run, not just a log line (H14)" do
      WikiStub.serve(%{categories: %{}, fail: &(&1["list"] == "categorymembers")})

      assert {:error, {:enumeration_failed, _}} = run_quietly(&ChaptersSync.do_run/0)
      assert Reporter.status()["ChaptersSync"].outcome == :error
    end
  end
end
