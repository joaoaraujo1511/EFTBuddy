defmodule EftBuddy.Wiki.EventQuestBlacklistTest do
  @moduledoc """
  The quest scrape leaves event quests to the events scrape, but only the ones
  that would show as WIP (audit H13).

  It used to drop every event-page title, including 24 that tarkov.dev serves as
  real tasks, so those tasks had no wiki guide on the Tasks tab.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog
  import EftBuddy.Fixtures, only: [task: 1]

  alias EftBuddy.Events.{Event, EventQuest}
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.Wiki.{FileLicense, QuestPage}
  alias EftBuddy.Wiki.Sync, as: WikiSync
  alias EftBuddy.WikiStub

  setup do
    Reporter.reset_status()
    FileLicense.clear_cache()
    on_exit(&Reporter.reset_status/0)

    # tarkov.dev serves "Saving Private Roman" as a task; "Cold Feet" exists only
    # on the wiki's Events page.
    task(%{name: "Saving Private Roman", normalized_name: "saving-private-roman"})

    event =
      Repo.insert!(%Event{normalized_name: "icebreaker", name: "Icebreaker", position: 0})

    for {slug, name} <- [
          {"saving-private-roman", "Saving Private Roman"},
          {"cold-feet", "Cold Feet"}
        ] do
      Repo.insert!(%EventQuest{
        event_id: event.id,
        normalized_name: slug,
        name: name,
        position: 0
      })
    end

    titles = ["Saving Private Roman", "Cold Feet", "Ordinary Quest"]

    WikiStub.serve(%{
      categories: %{"Category:Quests" => titles},
      pages: Map.new(titles, &{&1, WikiStub.page(sections: [{"Guide", "Guide for #{&1}."}])})
    })

    capture_log(fn -> {:ok, _} = WikiSync.do_run() end)
    :ok
  end

  defp row(slug), do: Repo.get_by(QuestPage, normalized_name: slug)

  test "an event quest that is a real task keeps its wiki guide, as that task" do
    roman = row("saving-private-roman")

    assert roman
    refute roman.wip
    assert roman.task_id
    assert inspect(roman.content) =~ "Guide for Saving Private Roman."
  end

  test "an event quest with no task is left to the Events tab, not shown as WIP" do
    refute row("cold-feet")
  end

  test "an ordinary wiki-only quest is still WIP" do
    assert row("ordinary-quest").wip
  end

  test "no quest is stored twice" do
    slugs = Repo.all(from q in QuestPage, select: q.normalized_name)
    assert Enum.sort(slugs) == ["ordinary-quest", "saving-private-roman"]
  end
end
