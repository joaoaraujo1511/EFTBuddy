defmodule EftBuddyWeb.StorylineLiveTest do
  @moduledoc """
  Mount tests for both storyline pages.

  These exist because a LiveView template that reads an assign its LiveView
  stopped setting compiles perfectly, passes every component test, and then
  raises `KeyError` on the *connected* mount — a blank page behind "Something
  went wrong. Attempting to reconnect." Only rendering the real page catches
  it, and the storyline pages have the most assign churn in the app: the
  endgame chapter shows one ending's guide and payout, the index's Endings
  tab shows the fork itself, and every other chapter is a walkthrough —
  three shapes wired from different data.
  """
  use EftBuddyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EftBuddy.Chapters.ChapterPage
  alias EftBuddy.Repo

  # A chapter row the way `EftBuddy.Chapters.Sync` stores it.
  defp insert_chapter(slug, name, sections) do
    content = %{
      "normalized_name" => slug,
      "chapter_name" => name,
      "wiki_title" => name,
      "wiki_link" => "https://escapefromtarkov.fandom.com/wiki/#{name}",
      "sections" => sections
    }

    %ChapterPage{}
    |> ChapterPage.changeset(%{normalized_name: slug, chapter_name: name, content: content})
    |> Repo.insert!()
  end

  defp section(attrs) do
    Map.merge(%{"slug" => "s", "level" => 2, "index" => "1", "files" => []}, attrs)
  end

  defp file(name, url), do: %{"wiki_filename" => name, "url" => url, "banner" => false}

  # The Endings reference page: one section per ending, each opening with
  # that ending's icon and closing with its rewards.
  defp insert_endings do
    sections =
      ~w(Savior Debtor)
      |> Enum.with_index(1)
      |> Enum.map(fn {name, idx} ->
        section(%{
          "slug" => String.downcase(name),
          "index" => to_string(idx),
          "heading" => name,
          "wikitext" =>
            "==#{name}==\n[[File:#{name} icon.png]]\nYou escaped as the #{name}.\n* Dogtag (#{name})",
          "files" => [file("#{name} icon.png", "https://cdn/#{String.downcase(name)}.png")]
        })
      end)

    insert_chapter("endings", "Endings", sections)
  end

  # The endgame chapter: a conditional objective block badged with the
  # endings it leads to, plus one transcluded branch guide per ending.
  defp insert_endgame do
    objectives =
      section(%{
        "slug" => "objectives",
        "index" => "1",
        "heading" => "Objectives",
        "wikitext" => "==Objectives==
* Obtain Intelligence Center level 1"
      })

    branch =
      section(%{
        "slug" => "accept",
        "level" => 3,
        "index" => "2",
        "heading" => "If you accept the offer",
        "wikitext" =>
          "===If you accept the offer [[File:Savior icon.png|Savior ending|74x74px|link=]]" <>
            "[[File:Debtor icon.png|Debtor ending|74x74px|link=]]===\n* Accept the offer",
        "files" => [
          file("Savior icon.png", "https://cdn/savior.png"),
          file("Debtor icon.png", "https://cdn/debtor.png")
        ]
      })

    guides =
      Enum.map(~w(Savior Debtor), fn name ->
        section(%{
          "slug" => "the_ticket_section_#{String.downcase(name)}_guide",
          "index" => "tmpl:Template:The_Ticket_Section_#{name}_Guide",
          "heading" => "The_Ticket_Section_#{name}_Guide",
          "wikitext" => "===Talk to Mr. Kerman===\nThe #{name} route."
        })
      end)

    insert_chapter("the-ticket", "The Ticket", [objectives, branch | guides])
  end

  defp insert_plain_chapter do
    insert_chapter("boreas", "Boreas", [
      section(%{"slug" => "guide", "heading" => "Guide", "wikitext" => "==Guide==\nHead north."})
    ])
  end

  describe "the index" do
    test "the chapter timeline renders", %{conn: conn} do
      insert_plain_chapter()

      {:ok, _view, html} = live(conn, ~p"/storyline")

      assert html =~ "Boreas"
    end

    test "the Endings tab lists the blocks the story forks into", %{conn: conn} do
      insert_endings()
      insert_endgame()

      {:ok, _view, html} = live(conn, ~p"/storyline?view=endings")

      assert html =~ "If you accept the offer"
      assert html =~ "Accept the offer"
      assert html =~ "Savior ending"
      assert html =~ "https://cdn/debtor.png"
    end

    test "the Endings tab is informational: it links to no particular ending",
         %{conn: conn} do
      insert_endings()
      insert_endgame()

      {:ok, _view, html} = live(conn, ~p"/storyline?view=endings")

      refute html =~ "?ending="
    end

    test "no ending's guide or rewards are on the index", %{conn: conn} do
      insert_endings()
      insert_endgame()

      {:ok, _view, html} = live(conn, ~p"/storyline?view=endings")

      refute html =~ "The Savior route."
      refute html =~ "Dogtag (Savior)"
    end

    test "the Endings tab falls back to the timeline when nothing is synced",
         %{conn: conn} do
      insert_plain_chapter()

      {:ok, _view, html} = live(conn, ~p"/storyline?view=endings")

      assert html =~ "Boreas"
      refute html =~ "Where the story forks"
    end

    test "the endgame chapter's card offers endings, not a walkthrough", %{conn: conn} do
      insert_endings()
      insert_endgame()

      {:ok, _view, html} = live(conn, ~p"/storyline")

      assert html =~ "Endings"
    end
  end

  describe "the endgame chapter" do
    setup do
      insert_endings()
      insert_endgame()
      :ok
    end

    test "opens on the first ending: its guide, then its rewards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/storyline/the-ticket")

      assert html =~ ~s(id="guide-savior")
      assert html =~ ~s(id="rewards-savior")
      assert html =~ "The Savior route."
      assert html =~ "Dogtag (Savior)"
      refute html =~ "The Debtor route."
    end

    test "the guide's heading names the ending it is for", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/storyline/the-ticket?ending=debtor")

      assert html =~ "Guide for the Debtor ending"
      refute html =~ "Guide for the Savior ending"
    end

    test "every ending gets a tab wearing its own icon", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/storyline/the-ticket")

      assert html =~ "?ending=savior"
      assert html =~ "?ending=debtor"
      assert html =~ "https://cdn/savior.png"
    end

    test "?ending= selects one, and only that one renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/storyline/the-ticket?ending=debtor")

      assert html =~ "The Debtor route."
      refute html =~ "The Savior route."
    end

    test "an unknown ?ending= falls back to the first rather than blanking",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/storyline/the-ticket?ending=nope")

      assert html =~ "The Savior route."
    end

    test "neither the shared objectives nor the fork are on the chapter page",
         %{conn: conn} do
      # Each branch guide walks its own objectives, and which branch leads
      # where is the index's Endings tab.
      {:ok, _view, html} = live(conn, ~p"/storyline/the-ticket")

      refute html =~ "Obtain Intelligence Center level 1"
      refute html =~ "If you accept the offer"
    end
  end

  describe "an ordinary chapter" do
    test "renders its walkthrough, with no ending tabs", %{conn: conn} do
      insert_endings()
      insert_plain_chapter()

      {:ok, _view, html} = live(conn, ~p"/storyline/boreas")

      assert html =~ "Head north."
      refute html =~ "?view="
    end

    test "an unknown chapter bounces back to the index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/storyline"}}} =
               live(conn, ~p"/storyline/not-a-chapter")
    end
  end
end
