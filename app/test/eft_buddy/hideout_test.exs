defmodule EftBuddy.HideoutTest do
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Fixtures
  alias EftBuddy.Hideout

  describe "list_modules/0" do
    test "returns one summary per station, name-sorted, with the max level" do
      med = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      Fixtures.station_level(%{station_id: med.id, level: 1})
      Fixtures.station_level(%{station_id: med.id, level: 2})
      Fixtures.station_level(%{station_id: med.id, level: 3})

      # A station with no levels should still appear with max: 0.
      Fixtures.station(%{name: "Stash", normalized_name: "stash"})

      assert [
               %{slug: "medstation", name: "Medstation", max: 3},
               %{slug: "stash", name: "Stash", max: 0}
             ] = Hideout.list_modules()
    end
  end

  describe "get_total_item_cost/2" do
    test "sums quantities per item across all levels up to the cap, roubles first" do
      station = Fixtures.station(%{name: "Generator", normalized_name: "generator"})
      l1 = Fixtures.station_level(%{station_id: station.id, level: 1})
      l2 = Fixtures.station_level(%{station_id: station.id, level: 2})
      l3 = Fixtures.station_level(%{station_id: station.id, level: 3})

      roubles = Fixtures.item(%{name: "Roubles", normalized_name: "roubles"})
      wires = Fixtures.item(%{name: "Wires", normalized_name: "wires"})

      Fixtures.item_requirement(%{level_id: l1.id, item_id: roubles.id, quantity: 50_000})
      Fixtures.item_requirement(%{level_id: l2.id, item_id: roubles.id, quantity: 150_000})
      Fixtures.item_requirement(%{level_id: l2.id, item_id: wires.id, quantity: 5})
      # Beyond the level-2 cap: must be excluded from the total.
      Fixtures.item_requirement(%{level_id: l3.id, item_id: wires.id, quantity: 99})

      assert [
               %{item: %{normalized_name: "roubles"}, quantity: 200_000},
               %{item: %{normalized_name: "wires"}, quantity: 5}
             ] = Hideout.get_total_item_cost("generator", 2)
    end

    test "returns [] for an unknown station or invalid level" do
      assert Hideout.get_total_item_cost("does-not-exist", 2) == []
      assert Hideout.get_total_item_cost("generator", 0) == []
    end
  end

  describe "get_level_requirements/2" do
    test "returns the four requirement lists, item requirements roubles-first" do
      station = Fixtures.station(%{name: "Lavatory", normalized_name: "lavatory"})
      level = Fixtures.station_level(%{station_id: station.id, level: 1})

      roubles = Fixtures.item(%{name: "Roubles", normalized_name: "roubles"})
      bolts = Fixtures.item(%{name: "Bolts", normalized_name: "bolts"})

      Fixtures.item_requirement(%{level_id: level.id, item_id: bolts.id, quantity: 3})
      Fixtures.item_requirement(%{level_id: level.id, item_id: roubles.id, quantity: 1_000})

      assert %{
               item_requirements: items,
               station_level_requirements: [],
               skill_requirements: [],
               trader_requirements: []
             } = Hideout.get_level_requirements("lavatory", 1)

      # Roubles sort ahead of everything, then alphabetical.
      assert Enum.map(items, & &1.item.normalized_name) == ["roubles", "bolts"]
    end

    test "returns nil for a missing station/level or invalid args" do
      Fixtures.station(%{name: "Lavatory", normalized_name: "lavatory"})

      assert Hideout.get_level_requirements("nope", 1) == nil
      assert Hideout.get_level_requirements("lavatory", 0) == nil
      assert Hideout.get_level_requirements("lavatory", "1") == nil
    end
  end
end
