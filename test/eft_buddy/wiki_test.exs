defmodule EftBuddy.WikiTest do
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Wiki
  alias EftBuddy.Wiki.QuestPage

  defp insert_page(attrs) do
    %QuestPage{}
    |> QuestPage.changeset(attrs)
    |> Repo.insert!()
  end

  describe "get_quest/1" do
    test "projects the stored content into the render-ready map" do
      insert_page(%{
        normalized_name: "golden-swag",
        name: "Golden Swag",
        wip: false,
        given_by: "Skier",
        content: %{
          "task_name" => "Golden Swag",
          "normalized_name" => "golden-swag",
          "given_by" => "Skier",
          "sections" => [
            %{
              "slug" => "objectives",
              "objectives" => [%{"index" => 1, "text" => "Find it"}],
              "files" => []
            }
          ]
        }
      })

      quest = Wiki.get_quest("golden-swag")
      assert quest.task_name == "Golden Swag"
      assert quest.objectives_text == [%{index: 1, text: "Find it"}]
    end

    test "returns nil for unknown or blank slugs" do
      assert Wiki.get_quest("nope") == nil
      assert Wiki.get_quest("") == nil
      assert Wiki.get_quest(nil) == nil
    end
  end

  describe "has_wiki?/1" do
    test "reflects presence of a row" do
      insert_page(%{normalized_name: "known", name: "Known", content: %{}})
      assert Wiki.has_wiki?("known")
      refute Wiki.has_wiki?("unknown")
      refute Wiki.has_wiki?(nil)
    end
  end

  describe "all_quests/0" do
    test "returns lightweight rows for the WIP merge" do
      insert_page(%{
        normalized_name: "a-quest",
        name: "A Quest",
        wip: true,
        given_by: "Ref",
        content: %{}
      })

      assert [%{normalized_name: "a-quest", task_name: "A Quest", given_by: "Ref", wip: true}] =
               Wiki.all_quests()
    end
  end

  describe "karma_requirements/0" do
    test "maps slugs to karma tuples from the denormalised columns" do
      insert_page(%{
        normalized_name: "gte-quest",
        name: "G",
        karma_kind: "gte",
        karma_value: 4,
        content: %{}
      })

      insert_page(%{
        normalized_name: "lte-quest",
        name: "L",
        karma_kind: "lte",
        karma_value: -1,
        content: %{}
      })

      insert_page(%{normalized_name: "no-karma", name: "N", content: %{}})

      reqs = Wiki.karma_requirements()
      assert reqs["gte-quest"] == {:gte, 4}
      assert reqs["lte-quest"] == {:lte, -1}
      refute Map.has_key?(reqs, "no-karma")
    end
  end
end
