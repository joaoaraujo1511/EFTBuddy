defmodule EftBuddy.Armor.MaterialTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Armor.Material

  describe "effective_durability/2" do
    test "divides durability by the material destructibility" do
      # Ceramic destructibility 0.6 -> 60 / 0.6 = 100
      assert Material.effective_durability(60, "Ceramic") == 100
      # ArmoredSteel 0.525 -> 50 / 0.525 = 95.2 -> 95
      assert Material.effective_durability(50, "ArmoredSteel") == 95
      # UHMWPE 0.3375 -> 45 / 0.3375 = 133.3 -> 133
      assert Material.effective_durability(45, "UHMWPE") == 133
    end

    test "falls back to raw durability for an unknown material" do
      assert Material.effective_durability(40, "Unobtanium") == 40
    end

    test "nil durability passes through" do
      assert Material.effective_durability(nil, "Ceramic") == nil
    end
  end

  describe "label/1" do
    test "humanizes tokens that need it, passes the rest through" do
      assert Material.label("ArmoredSteel") == "Armored Steel"
      assert Material.label("Combined") == "Combined Materials"
      assert Material.label("Ceramic") == "Ceramic"
      assert Material.label(nil) == "Unknown"
    end
  end

  describe "explosive_destructibility/1" do
    test "returns the blast destructibility factor for known materials" do
      assert Material.explosive_destructibility("Aramid") == 0.15
      assert Material.explosive_destructibility("ArmoredSteel") == 0.45
      assert Material.explosive_destructibility("Glass") == 0.6
    end

    test "returns nil for an unknown material" do
      assert Material.explosive_destructibility("Unobtanium") == nil
    end
  end

  describe "reference/0" do
    test "lists every material with both destructibility factors, softest first" do
      rows = Material.reference()

      assert length(rows) == 8
      assert hd(rows).token == "Aramid"
      assert List.last(rows).token == "Glass"

      steel = Enum.find(rows, &(&1.token == "ArmoredSteel"))
      assert steel.label == "Armored Steel"
      assert steel.destructibility == 0.525
      assert steel.explosive_destructibility == 0.45
    end
  end
end
