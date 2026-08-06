defmodule EftBuddyWeb.TasksLiveTest do
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  test "lists tasks and shows per-status counts in the options bar", %{conn: conn} do
    trader = trader(%{name: "Prapor", normalized_name: "prapor"})
    task(%{name: "Debut", trader_id: trader.id})

    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "Debut"
    # ALL tab reflects the single task via a count badge.
    assert html =~ ~r/text-\[10px\][^>]*>\s*1\s*</
  end

  test "the COMPLETED filter is reachable and renders its empty state", %{conn: conn} do
    task(%{name: "Debut"})

    {:ok, view, _html} = live(conn, ~p"/tasks")
    html = render_patch(view, ~p"/tasks?status=completed")

    # Nothing is completed yet (no per-player progress), so the count is 0.
    assert html =~ "Completed"
    assert html =~ ~r/text-\[10px\][^>]*>\s*0\s*</
  end

  describe "quest banners" do
    # There was no coverage of banner placement anywhere in the web tests, which
    # is how the two sources came to disagree about it: an API-backed quest
    # rendered its banner as a thumbnail on the collapsed row, while a wiki-only
    # (WIP) quest rendered an empty placeholder there and put its banner inside
    # the expandable panel instead.

    test "an API-backed quest shows its banner on the collapsed row", %{conn: conn} do
      task(%{name: "Debut", task_image_link: "https://example.test/debut.jpg"})

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "https://example.test/debut.jpg"
    end

    test "a wiki-only quest shows its banner in the same place", %{conn: conn} do
      # THE BUG. `wip_view_model/1` hardcoded `banner_url: nil` because
      # `Wiki.all_quests/0` never read the manifest the banner lived in, so this
      # row rendered an empty 112x48 placeholder while every other row had a
      # thumbnail. The banner was scraped and stored the whole time — it just was
      # not reachable at list time until it became a column.
      EftBuddy.Repo.insert!(%EftBuddy.Wiki.QuestPage{
        normalized_name: "wiki-only-quest",
        name: "Wiki Only Quest",
        wip: true,
        banner_url: "https://example.test/wiki-only.png",
        content: %{}
      })

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Wiki Only Quest"

      assert html =~ "https://example.test/wiki-only.png",
             "a wiki-only quest must render its banner on the row, like every other quest"
    end

    test "a wiki-only quest without a banner renders without one", %{conn: conn} do
      EftBuddy.Repo.insert!(%EftBuddy.Wiki.QuestPage{
        normalized_name: "bannerless-quest",
        name: "Bannerless Quest",
        wip: true,
        content: %{}
      })

      {:ok, _view, html} = live(conn, ~p"/tasks")

      assert html =~ "Bannerless Quest"
    end
  end
end
