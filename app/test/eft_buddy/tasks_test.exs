defmodule EftBuddy.TasksTest do
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Fixtures
  alias EftBuddy.Tasks
  alias EftBuddy.Tasks.Objective

  defp names(rows), do: Enum.map(rows, & &1.name)

  describe "list_tasks/1" do
    test "defaults to name ascending and preloads associations" do
      Fixtures.task(%{name: "Bravo"})
      Fixtures.task(%{name: "Alpha"})

      [first | _] = tasks = Tasks.list_tasks()

      assert names(tasks) == ["Alpha", "Bravo"]
      # Default preloads should materialize objectives (not NotLoaded).
      assert is_list(first.objectives)
    end

    test "filters by trader slug" do
      prapor = Fixtures.trader(%{name: "Prapor", normalized_name: "prapor"})
      therapist = Fixtures.trader(%{name: "Therapist", normalized_name: "therapist"})
      Fixtures.task(%{name: "Debut", trader_id: prapor.id})
      Fixtures.task(%{name: "Shortage", trader_id: therapist.id})

      assert names(Tasks.list_tasks(trader_slug: "prapor")) == ["Debut"]
    end

    test "faction filter returns the faction's tasks plus faction-neutral ones" do
      Fixtures.task(%{name: "Usec Only", faction_name: "USEC"})
      Fixtures.task(%{name: "Bear Only", faction_name: "BEAR"})
      Fixtures.task(%{name: "Neutral", faction_name: nil})

      assert names(Tasks.list_tasks(faction: :usec)) == ["Neutral", "Usec Only"]
      assert names(Tasks.list_tasks(faction: :bear)) == ["Bear Only", "Neutral"]
      assert names(Tasks.list_tasks(faction: nil)) == ["Bear Only", "Neutral", "Usec Only"]
    end
  end

  describe "prereq_map/0" do
    test "maps each task to its complete-status prerequisites only" do
      task = Fixtures.task(%{name: "Part 2"})
      done = Fixtures.task(%{name: "Part 1"})
      active = Fixtures.task(%{name: "Side Quest"})

      Fixtures.task_requirement(%{
        task_id: task.id,
        prerequisite_task_id: done.id,
        status: ["complete"]
      })

      # An "active"-status prerequisite must be ignored.
      Fixtures.task_requirement(%{
        task_id: task.id,
        prerequisite_task_id: active.id,
        status: ["active"]
      })

      map = Tasks.prereq_map()

      assert Map.fetch!(map, task.id) == MapSet.new([done.id])
    end
  end

  describe "required_items_for/1" do
    test "merges metadata across objectives (FiR wins, count is the max), sorted by name" do
      apple = Fixtures.item(%{name: "Apple"})
      key = Fixtures.item(%{name: "Banana Key"})

      # required_items_for/1 only reads each objective's payload, so
      # these don't need to be persisted (and need no parent task).
      objectives = [
        %Objective{payload: %{"items" => [apple.id], "count" => 2, "foundInRaid" => true}},
        %Objective{payload: %{"items" => [apple.id], "count" => 5, "foundInRaid" => false}},
        %Objective{payload: %{"required_key_ids" => [key.id]}}
      ]

      assert [
               %{item: %{name: "Apple"}, found_in_raid: true, count: 5},
               %{item: %{name: "Banana Key"}, found_in_raid: false, count: nil}
             ] = Tasks.required_items_for(%{objectives: objectives})
    end

    test "returns [] when there are no objectives" do
      assert Tasks.required_items_for(%{objectives: []}) == []
      assert Tasks.required_items_for(%{}) == []
    end
  end

  describe "traders_with_tasks/0" do
    test "returns only traders that own at least one task, ordered by name" do
      prapor = Fixtures.trader(%{name: "Prapor", normalized_name: "prapor"})
      therapist = Fixtures.trader(%{name: "Therapist", normalized_name: "therapist"})
      # Skier has no tasks and must not appear.
      Fixtures.trader(%{name: "Skier", normalized_name: "skier"})

      Fixtures.task(%{name: "Debut", trader_id: prapor.id})
      Fixtures.task(%{name: "Shortage", trader_id: therapist.id})

      assert names(Tasks.traders_with_tasks()) == ["Prapor", "Therapist"]
    end
  end
end
