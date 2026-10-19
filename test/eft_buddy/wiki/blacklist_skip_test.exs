defmodule EftBuddy.Wiki.BlacklistSkipTest do
  @moduledoc """
  Blacklisted quest pages (Ref quests, `{{Historical content}}`) are not
  re-fetched while their revision is unchanged (audit finding N2).

  They get no `wiki_quests` row, so there was no stored revision to compare and
  every run fetched all ~197 of them again, only to skip them. The verdict
  depends on nothing but the page's own lead section, so the revision it was
  reached at is enough to trust it.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog
  import EftBuddy.Fixtures, only: [task: 1]

  alias EftBuddy.Sync.Reporter
  alias EftBuddy.Wiki.{BlacklistedPage, FileLicense, QuestPage}
  alias EftBuddy.Wiki.Sync, as: WikiSync
  alias EftBuddy.WikiStub

  @ref_lead "{{Infobox quest\n|given by=[[Ref]]\n}}\nAn arena quest."

  setup do
    Reporter.reset_status()
    FileLicense.clear_cache()
    on_exit(fn -> Reporter.reset_status() end)

    task(%{name: "Some Real Task", normalized_name: "some-real-task"})
    :ok
  end

  # Ten ordinary quests, so a prune of the blacklisted row stays inside the
  # prune guard's ratio, plus one Ref quest at `ref_revid`.
  defp serve(ref_revid, opts \\ []) do
    test = self()
    real = for i <- 1..10, do: "Quest #{i}"

    pages =
      Map.new(real, &{&1, WikiStub.page(revid: 10, sections: [{"Guide", "Do the thing."}])})
      |> Map.put(
        "Arena Quest",
        WikiStub.page(revid: ref_revid, lead: Keyword.get(opts, :lead, @ref_lead))
      )

    WikiStub.serve(%{
      categories: %{"Category:Quests" => real ++ ["Arena Quest"]},
      pages: pages,
      observe: fn params ->
        if params["action"] == "parse" and params["page"] == "Arena Quest",
          do: send(test, :arena_fetched)
      end
    })
  end

  defp run do
    capture_log(fn -> send(self(), {:result, WikiSync.run()}) end)
    assert_received {:result, result}
    result
  end

  defp fetched? do
    receive do
      :arena_fetched -> flush_fetches() || true
    after
      0 -> false
    end
  end

  defp flush_fetches do
    receive do
      :arena_fetched -> flush_fetches()
    after
      0 -> nil
    end
  end

  test "a blacklisted page is remembered at its revision and not fetched again" do
    serve(5)
    assert {:ok, %{blacklisted: 1}} = run()
    assert fetched?()

    assert [%BlacklistedPage{wiki_title: "Arena Quest", revision_id: 5, reason: "ref"}] =
             Repo.all(BlacklistedPage)

    assert {:ok, %{blacklisted: 1}} = run()
    refute fetched?(), "an unedited blacklisted page was fetched again"
    refute Repo.get_by(QuestPage, normalized_name: "arena-quest")
  end

  test "an edited blacklisted page is fetched and judged again" do
    serve(5)
    run()
    fetched?()

    serve(6)
    run()
    assert fetched?()
    assert [%BlacklistedPage{revision_id: 6}] = Repo.all(BlacklistedPage)
  end

  test "a page that is no longer blacklisted gets its row, and leaves the list" do
    serve(5)
    run()

    serve(6, lead: "{{Infobox quest\n|given by=[[Prapor]]\n}}\nNow a normal quest.")
    run()

    assert Repo.get_by(QuestPage, normalized_name: "arena-quest")
    assert Repo.all(BlacklistedPage) == []
  end

  test "a skipped blacklisted page still keeps its stale row out of the table" do
    serve(5)
    run()
    assert fetched?()

    # A row a much older run wrote, before the page was blacklisted.
    Repo.insert!(%QuestPage{normalized_name: "arena-quest", name: "Arena Quest", content: %{}})

    serve(5)
    run()
    refute fetched?(), "an unedited blacklisted page was fetched again"
    refute Repo.get_by(QuestPage, normalized_name: "arena-quest")
  end
end
