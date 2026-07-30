defmodule EftBuddy.ChaptersTest do
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Chapters
  alias EftBuddy.Chapters.ChapterPage

  # Insert a chapter row whose `content` is a minimal but valid manifest
  # (the shape the sync stores and the projection reads).
  defp insert_chapter(slug, name, sections \\ []) do
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

  # A "Related Quest Items" wikitable section, the way the manifest
  # retains it (raw wikitext + string keys).
  defp items_section do
    %{
      "slug" => "guide",
      "level" => 2,
      "index" => "1",
      "heading" => "Guide",
      "wikitext" => "{|\n! Item Name\n! Amount\n|-\n| [[Bottle of Vodka]]\n| 2\n|}",
      "files" => []
    }
  end

  describe "list_chapters/0" do
    test "returns chapters in the curated narrative order and excludes Endings" do
      # Inserted out of order on purpose.
      insert_chapter("boreas", "Boreas")
      insert_chapter("tour", "Tour")
      insert_chapter("endings", "Endings")
      # Not in the curated @order — sorts last, alphabetically by name.
      insert_chapter("epilogue", "Epilogue")

      slugs = Chapters.list_chapters() |> Enum.map(& &1.normalized_name)

      # tour (index 0) before boreas (index 6); epilogue last; endings absent.
      assert slugs == ["tour", "boreas", "epilogue"]
    end

    test "returns [] when nothing is synced" do
      assert Chapters.list_chapters() == []
    end
  end

  describe "get_chapter/1" do
    test "projects the stored content into the render-ready map" do
      insert_chapter("boreas", "Boreas", [items_section()])

      chapter = Chapters.get_chapter("boreas")
      assert chapter.normalized_name == "boreas"
      assert chapter.chapter_name == "Boreas"
      assert [%{name: "Bottle of Vodka", page: "Bottle of Vodka"}] = chapter.items
    end

    test "returns nil for unknown or blank slugs" do
      assert Chapters.get_chapter("nope") == nil
      assert Chapters.get_chapter("") == nil
      assert Chapters.get_chapter(nil) == nil
    end
  end

  describe "get_endings/0" do
    test "returns the Endings reference page, or nil when not synced" do
      assert Chapters.get_endings() == nil
      insert_chapter("endings", "Endings")
      assert Chapters.get_endings().normalized_name == "endings"
    end
  end

  describe "chapters_for_item/1" do
    test "finds chapters whose related items reference the given item by name" do
      insert_chapter("boreas", "Boreas", [items_section()])

      assert [%{slug: "boreas", title: "Boreas"}] =
               Chapters.chapters_for_item(%{name: "Bottle of vodka"})

      assert Chapters.chapters_for_item(%{name: "Something Else"}) == []
      assert Chapters.chapters_for_item(%{}) == []
    end
  end
end
