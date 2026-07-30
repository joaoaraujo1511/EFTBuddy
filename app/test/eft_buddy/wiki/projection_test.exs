defmodule EftBuddy.Wiki.ProjectionTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Wiki.Projection

  # A manifest as it comes back from the JSONB `content` column:
  # string-keyed, exactly like the old on-disk `_quest.json`.
  defp manifest(sections, extra \\ %{}) do
    Map.merge(
      %{
        "task_id" => "uuid-1",
        "task_name" => "Golden Swag",
        "normalized_name" => "golden-swag",
        "wip" => false,
        "given_by" => "Skier",
        "sections" => sections
      },
      extra
    )
  end

  test "carries through the scalar fields" do
    p = Projection.project(manifest([]))

    assert p.task_id == "uuid-1"
    assert p.task_name == "Golden Swag"
    assert p.normalized_name == "golden-swag"
    assert p.given_by == "Skier"
    refute p.wip
  end

  test "extracts objectives text from the objectives section" do
    sections = [
      %{
        "slug" => "objectives",
        "objectives" => [
          %{"index" => 1, "text" => "Find the key"},
          %{"index" => 2, "text" => ""}
        ],
        "files" => []
      }
    ]

    p = Projection.project(manifest(sections))
    assert p.objectives_text == [%{index: 1, text: "Find the key"}]
  end

  test "builds guide blocks (prose + gallery) from the guide wikitext" do
    sections = [
      %{
        "slug" => "guide",
        "level" => "2",
        "wikitext" => "Head to the spot.\n<gallery>\nFile:Spot.png|the spot\n</gallery>",
        "files" => [
          %{"wiki_filename" => "Spot.png", "url" => "https://cdn/spot.png", "caption" => nil}
        ]
      }
    ]

    p = Projection.project(manifest(sections))

    assert [%{kind: :prose, text: "Head to the spot."}, %{kind: :gallery, images: [img]}] =
             p.guide

    assert img.file["url"] == "https://cdn/spot.png"
    assert img.caption == "the spot"
  end

  test "drops bottom-of-page interlanguage links from the guide" do
    # Regression: the Guide is often the last `==` section, so the page's
    # trailing interlanguage links (`[[FR:…]]`, `[[cs:…]]`, `[[ru:…]]`) and
    # `[[Category:…]]` land in its wikitext. None of them are guide prose.
    sections = [
      %{
        "slug" => "guide",
        "level" => "2",
        "wikitext" =>
          "Real guide text here.\n\n[[Category:Quests]]\n\n[[FR:Swag - Partie 1]]\n[[cs:Vystrojení se - Část 1]]\n[[ru:Обновка. Часть 1]]",
        "files" => []
      }
    ]

    p = Projection.project(manifest(sections))

    assert p.guide == [%{kind: :prose, text: "Real guide text here."}]
  end

  test "extracts the banner url from the file flagged banner: true" do
    sections = [
      %{
        "slug" => "lead",
        "files" => [%{"banner" => true, "url" => "https://cdn/banner.png"}]
      }
    ]

    assert Projection.project(manifest(sections)).banner == %{url: "https://cdn/banner.png"}
  end

  describe "karma_requirement/1" do
    defp with_req(text) do
      manifest([%{"slug" => "requirements", "objectives" => [%{"index" => 1, "text" => text}]}])
    end

    test "parses 'at least +N' as :gte" do
      assert Projection.karma_requirement(with_req("Scav karma of at least +4")) == {:gte, 4}
    end

    test "parses 'of -N' as :lte with a negative threshold" do
      assert Projection.karma_requirement(with_req("Scav karma of -1")) == {:lte, -1}
    end

    test "is nil when there's no karma requirement" do
      assert Projection.karma_requirement(with_req("Reach level 10")) == nil
      assert Projection.karma_requirement(manifest([])) == nil
    end
  end
end
