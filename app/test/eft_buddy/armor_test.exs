defmodule EftBuddy.ArmorTest do
  use EftBuddy.DataCase, async: true

  import EftBuddy.Fixtures

  alias EftBuddy.Armor
  alias EftBuddy.Armor.Plate

  defp plate(attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      external_id: "plate-#{n}",
      class: 4,
      durability: 40,
      material: "Ceramic",
      armor_type: "Heavy",
      blunt_throughput: 0.3,
      speed_penalty: -0.02,
      turn_penalty: -0.01,
      ergo_penalty: -0.01,
      repair_cost: 100
    }

    Repo.insert!(struct(Plate, Map.merge(defaults, Map.new(attrs))))
  end

  test "list_plates/0 preloads the linked item" do
    it = item(%{name: "ESAPI level IV ballistic plate"})
    plate(%{item_id: it.id})

    assert [p] = Armor.list_plates()
    assert p.item.name == "ESAPI level IV ballistic plate"
  end

  describe "group_by_class/1" do
    test "groups by class (highest first) with the toughest plate first in each class" do
      a = item(%{name: "Ceramic 6"})
      b = item(%{name: "Steel 6"})
      c = item(%{name: "Ceramic 4"})

      # class 6: Ceramic 60 -> eff 100; ArmoredSteel 50 -> eff ~95
      plate(%{item_id: a.id, class: 6, durability: 60, material: "Ceramic"})
      plate(%{item_id: b.id, class: 6, durability: 50, material: "ArmoredSteel"})
      plate(%{item_id: c.id, class: 4, durability: 40, material: "Ceramic"})

      assert [{6, class6}, {4, class4}] = Armor.group_by_class(Armor.list_plates())
      assert Enum.map(class6, & &1.item.name) == ["Ceramic 6", "Steel 6"]
      assert Enum.map(class4, & &1.item.name) == ["Ceramic 4"]
    end
  end

  describe "group_by_class/2 with an explicit sort" do
    test "sorts within a class by the requested column and direction" do
      a = item(%{name: "High durability"})
      b = item(%{name: "Low durability"})

      plate(%{item_id: a.id, class: 5, durability: 60, material: "Ceramic"})
      plate(%{item_id: b.id, class: 5, durability: 30, material: "Ceramic"})

      assert [{5, asc}] = Armor.group_by_class(Armor.list_plates(), :durability_asc)
      assert Enum.map(asc, & &1.item.name) == ["Low durability", "High durability"]

      assert [{5, desc}] = Armor.group_by_class(Armor.list_plates(), :durability_desc)
      assert Enum.map(desc, & &1.item.name) == ["High durability", "Low durability"]
    end

    test "keeps classes in highest-first order regardless of the within-class sort" do
      c4 = item(%{name: "Class 4 plate"})
      c6 = item(%{name: "Class 6 plate"})

      plate(%{item_id: c4.id, class: 4})
      plate(%{item_id: c6.id, class: 6})

      assert [{6, _}, {4, _}] = Armor.group_by_class(Armor.list_plates(), :durability_asc)
    end
  end
end
