defmodule EftBuddy.Ammo.CaliberTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Ammo.Caliber

  describe "label/1" do
    test "maps known caliber enums to display labels" do
      assert Caliber.label("Caliber556x45NATO") == "5.56x45mm NATO"
      assert Caliber.label("Caliber762x54R") == "7.62x54mmR"
      assert Caliber.label("Caliber12g") == "12/70"
      assert Caliber.label("Caliber86x70") == ".338 Lapua Magnum"
    end

    test "falls back to stripping the Caliber prefix for unknown enums" do
      assert Caliber.label("Caliber999x99") == "999x99"
    end

    test "handles nil / non-binary gracefully" do
      assert Caliber.label(nil) == "Unknown"
    end
  end

  describe "order/1" do
    test "orders pistol calibers before rifle before shotgun before grenades" do
      pistol = Caliber.order("Caliber9x19PARA")
      rifle = Caliber.order("Caliber556x45NATO")
      shotgun = Caliber.order("Caliber12g")
      grenade = Caliber.order("Caliber40mmRU")

      assert pistol < rifle
      assert rifle < shotgun
      assert shotgun < grenade
    end

    test "unknown calibers sort after every known caliber" do
      assert Caliber.order("Caliber999x99") > Caliber.order("Caliber40mmRU")
    end
  end

  describe "known?/1" do
    test "true for mapped, false otherwise" do
      assert Caliber.known?("Caliber556x45NATO")
      refute Caliber.known?("Caliber999x99")
      refute Caliber.known?(nil)
    end
  end
end
