defmodule EftBuddy.Chapters.ProjectionTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Chapters.Projection

  # Build a string-keyed manifest the way it's stored in the
  # `wiki_chapters.content` JSONB column (and read back by Ecto).
  defp manifest(overrides \\ %{}) do
    Map.merge(
      %{
        "normalized_name" => "boreas",
        "chapter_name" => "Boreas",
        "wiki_title" => "Boreas",
        "wiki_link" => "https://escapefromtarkov.fandom.com/wiki/Boreas",
        "banner" => %{"url" => "https://cdn/banner.png"},
        "related_links" => [
          %{"title" => "Some Quest", "slug" => "some-quest"},
          %{"oops" => true}
        ],
        "summary" => %{"total_objectives" => 3},
        "sections" => [
          %{
            "slug" => "lead",
            "level" => 0,
            "index" => "0",
            "heading" => "(lead / infobox)",
            "wikitext" => "infobox stuff",
            "files" => []
          },
          %{
            "slug" => "description",
            "level" => 2,
            "index" => "1",
            "heading" => "Description",
            "wikitext" => "{{quote|A cold and unforgiving place.|Narrator}}",
            "files" => []
          },
          %{
            "slug" => "guide",
            "level" => 2,
            "index" => "2",
            "heading" => "Guide",
            "wikitext" =>
              "Head north to the lighthouse.\n<gallery>\nFile:Shot.png|A screenshot\n</gallery>",
            "files" => [
              %{"wiki_filename" => "Shot.png", "url" => "https://cdn/shot.png", "banner" => false}
            ]
          }
        ]
      },
      overrides
    )
  end

  describe "project/1" do
    test "drops the lead/infobox section but keeps the real sections in order" do
      slugs = Projection.project(manifest()).content_sections |> Enum.map(& &1.slug)
      assert slugs == ["description", "guide"]
    end

    test "extracts the infobox banner url, or nil when absent" do
      assert Projection.project(manifest()).banner == %{url: "https://cdn/banner.png"}
      assert Projection.project(manifest(%{"banner" => nil})).banner == nil
    end

    test "pulls the lore summary out of the Description {{quote}}" do
      assert Projection.project(manifest()).summary == "A cold and unforgiving place."
    end

    test "normalizes related links and drops malformed entries" do
      assert Projection.project(manifest()).related_links ==
               [%{title: "Some Quest", slug: "some-quest"}]
    end

    test "counts only gallery images and surfaces the objective count" do
      projected = Projection.project(manifest())
      assert projected.image_count == 1
      assert projected.objective_count == 3
    end

    test "passes identity fields through and retains the raw sections" do
      projected = Projection.project(manifest())
      assert projected.normalized_name == "boreas"
      assert projected.chapter_name == "Boreas"
      assert projected.wiki_title == "Boreas"
      assert length(projected.sections) == 3
    end

    test "returns nil for non-map input" do
      assert Projection.project(:nope) == nil
    end
  end
end
