defmodule EftBuddy.Chapters.DumpTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Chapters.Dump

  describe "chapter_from_title/1" do
    test "derives display title, slug and wiki link" do
      assert %{
               wiki_title: "Boreas",
               title: "Boreas",
               normalized_name: "boreas",
               wiki_link: "https://escapefromtarkov.fandom.com/wiki/Boreas"
             } = Dump.chapter_from_title("Boreas")
    end

    test "strips the ' (story chapter)' disambiguation suffix from the display title only" do
      chapter = Dump.chapter_from_title("The Labyrinth (story chapter)")

      assert chapter.title == "The Labyrinth"
      assert chapter.normalized_name == "the-labyrinth"
      # the real page title (used for fetching) keeps the suffix
      assert chapter.wiki_title == "The Labyrinth (story chapter)"
      assert chapter.wiki_link =~ "The_Labyrinth_(story_chapter)"
    end
  end

  describe "hub_page?/1" do
    test "the self-titled category hub is not a chapter" do
      assert Dump.hub_page?("Story chapters")
      assert Dump.hub_page?("  Story chapters  ")
      refute Dump.hub_page?("Boreas")
    end
  end

  describe "build_chapters/1" do
    test "drops the hub, de-dupes by slug, and sorts by title" do
      chapters = Dump.build_chapters(["Tour", "Story chapters", "Boreas", "Boreas"])

      assert Enum.map(chapters, & &1.normalized_name) == ["boreas", "tour"]
    end
  end

  describe "select_chapters/2" do
    setup do
      %{chapters: Dump.build_chapters(["Boreas", "Tour"])}
    end

    test "nil selection returns the full list", %{chapters: chapters} do
      assert Dump.select_chapters(chapters, nil) == chapters
    end

    test "a known slug narrows to that one chapter", %{chapters: chapters} do
      assert [%{normalized_name: "boreas"}] = Dump.select_chapters(chapters, "boreas")
    end

    test "an unknown slug is reported, not silently empty", %{chapters: chapters} do
      assert Dump.select_chapters(chapters, "nope") == {:unrecognized, "nope"}
    end
  end

  describe "parse_sections/1" do
    setup do
      parsed =
        Dump.parse_sections(%{
          lead_wikitext: "Intro about [[Some Quest]].",
          sections: [
            %{
              index: 1,
              heading: "Objectives",
              level: 2,
              wikitext:
                "* Do the thing\n<gallery>\nFile:Shot.png|a caption\n</gallery>\n[[Other Quest]]"
            }
          ]
        })

      %{parsed: parsed}
    end

    test "synthesises the lead as section 0", %{parsed: parsed} do
      lead = hd(parsed.sections)
      assert lead.index == "0"
      assert lead.slug == "lead"
    end

    test "extracts list objectives", %{parsed: parsed} do
      objectives = Enum.find(parsed.sections, &(&1.slug == "objectives")).objectives
      assert [%{index: 1, level: 1, text: "Do the thing"}] = objectives
    end

    test "extracts <gallery> filenames (not just [[File:]] links) for resolution", %{
      parsed: parsed
    } do
      assert "Shot.png" in parsed.image_filenames
    end

    test "collects non-file wikilinks as related links", %{parsed: parsed} do
      slugs = Enum.map(parsed.related_links, & &1.slug)
      assert "some-quest" in slugs
      assert "other-quest" in slugs
    end
  end

  describe "build_manifest/3" do
    test "assembles the manifest shape with summary counts" do
      chapter = Dump.chapter_from_title("Boreas")

      parsed =
        Dump.parse_sections(%{
          lead_wikitext: "",
          sections: [
            %{
              index: 1,
              heading: "Objectives",
              level: 2,
              wikitext: "* Do the thing\n[[File:Shot.png]]"
            }
          ]
        })

      resolved = %{"Shot.png" => %{"url" => "https://cdn/shot.png", "mime" => "image/png"}}

      manifest = Dump.build_manifest(chapter, parsed, resolved)

      assert manifest.chapter_name == "Boreas"
      assert manifest.normalized_name == "boreas"
      assert manifest.summary.total_objectives == 1
      assert manifest.summary.total_images == 1
      assert is_list(manifest.sections)
    end
  end
end
