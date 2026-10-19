defmodule EftBuddy.Events.SyncConditionalFetchTest do
  @moduledoc """
  The events scrape only re-fetches event quest pages edited since it last
  stored them (audit M22). It used to fetch all ~250 every twelve hours: 14-16
  minutes and ~1,700 requests per run against a wiki that rate-limits.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Events.{Event, EventQuest}
  alias EftBuddy.Events.Sync, as: EventsSync
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.Wiki.FileLicense
  alias EftBuddy.WikiStub

  @page """
  ==Wild Wild Woods (25 June 2026)==
  * Quest [[Wild Wild Woods]] has been added.
  * Quest [[Cold Feet]] has been added.
  """

  setup do
    Reporter.reset_status()
    FileLicense.clear_cache()
    on_exit(&Reporter.reset_status/0)

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    %{counter: counter}
  end

  defp wiki(counter, opts) do
    revids = Keyword.get(opts, :revids, %{})

    %{
      pages: %{
        "Events" => WikiStub.page(full: Keyword.get(opts, :events_page, @page)),
        "Wild Wild Woods" =>
          WikiStub.page(revid: revids["Wild Wild Woods"] || 1, sections: [{"Guide", "Woods."}]),
        "Cold Feet" =>
          WikiStub.page(revid: revids["Cold Feet"] || 1, sections: [{"Guide", "Warm."}])
      },
      fail: Keyword.get(opts, :fail, fn _ -> false end),
      # Count section fetches: the expensive part a probe is meant to save.
      observe: fn params ->
        if params["action"] == "parse" and params["page"] != "Events",
          do: Agent.update(counter, &(&1 + 1))
      end
    }
  end

  defp run(counter, opts \\ []) do
    Agent.update(counter, fn _ -> 0 end)
    WikiStub.serve(wiki(counter, opts))
    capture_log(fn -> send(self(), {:result, EventsSync.do_run()}) end)
    assert_received {:result, result}
    {result, Agent.get(counter, & &1)}
  end

  defp quest(slug), do: Repo.get_by!(EventQuest, normalized_name: slug)

  test "a second run with nothing edited fetches no quest page, and keeps the walkthroughs",
       %{counter: c} do
    {{:ok, %{scraped: 2, unchanged: 0}}, fetched} = run(c)
    assert fetched > 0

    {{:ok, %{scraped: 0, unchanged: 2}}, fetched} = run(c)
    assert fetched == 0

    assert inspect(quest("cold-feet").content) =~ "Warm."
    assert quest("cold-feet").revision_id == 1
  end

  test "only the edited page is fetched again", %{counter: c} do
    run(c)

    {{:ok, %{scraped: 1, unchanged: 1}}, _} = run(c, revids: %{"Cold Feet" => 2})
    assert quest("cold-feet").revision_id == 2
    assert quest("wild-wild-woods").revision_id == 1
  end

  test "a page scraped with a failed section is stored without a revision and retried",
       %{counter: c} do
    run(c, fail: &(&1["page"] == "Cold Feet" and &1["section"] == "1"))
    assert quest("cold-feet").revision_id == nil

    # Unedited, but incomplete last time: scraped again.
    {{:ok, %{scraped: 1, unchanged: 1}}, _} = run(c)
    assert quest("cold-feet").revision_id == 1
    assert inspect(quest("cold-feet").content) =~ "Warm."
  end

  test "an unedited page whose quest tarkov.dev has since added is scraped again",
       %{counter: c} do
    # Stored as WIP: no task matched "Cold Feet" when it was scraped.
    run(c)
    assert quest("cold-feet").content["wip"] == true

    # Now tarkov.dev serves it. The page is unedited, but the stored walkthrough
    # was parsed for a WIP quest, so it has to be scraped as a real one.
    EftBuddy.Fixtures.task(%{name: "Cold Feet", normalized_name: "cold-feet"})

    {{:ok, %{scraped: 1, unchanged: 1}}, _} = run(c)
    assert quest("cold-feet").content["wip"] == false
    assert quest("cold-feet").task_id

    {{:ok, %{scraped: 0, unchanged: 2}}, 0} = run(c)
  end

  test "a quest listed by a second event reuses the stored walkthrough", %{counter: c} do
    run(c)

    page = @page <> "==Frost Bite (10 January 2026)==\n* Quest [[Cold Feet]] has been added.\n"
    {{:ok, %{scraped: 0}}, 0} = run(c, events_page: page)

    frost = Repo.get_by!(Event, normalized_name: "frost-bite-10-january-2026")
    row = Repo.get_by!(EventQuest, event_id: frost.id, normalized_name: "cold-feet")
    assert inspect(row.content) =~ "Warm."
  end
end
