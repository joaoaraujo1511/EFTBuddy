defmodule EftBuddy.AmmoTest do
  use EftBuddy.DataCase, async: true

  import EftBuddy.Fixtures

  alias EftBuddy.Ammo
  alias EftBuddy.Ammo.Round

  # Insert an ammo round with sensible ballistics defaults.
  defp ammo_round(attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      external_id: "ammo-#{n}",
      caliber: "Caliber556x45NATO",
      ammo_type: "bullet",
      damage: 50,
      penetration_power: 30,
      penetration_chance: 0.5,
      armor_damage: 40,
      ricochet_chance: 0.3,
      accuracy_modifier: 0.0,
      recoil_modifier: 0.0,
      initial_speed: 900.0,
      projectile_count: 1,
      light_bleed_modifier: 0.0,
      heavy_bleed_modifier: 0.0,
      stack_max_size: 60,
      tracer: false,
      tracer_color: "red"
    }

    Repo.insert!(struct(Round, Map.merge(defaults, Map.new(attrs))))
  end

  describe "filter/2" do
    setup do
      ammo_round(%{item_id: item(%{name: "5.56 M855"}).id, caliber: "Caliber556x45NATO"})
      ammo_round(%{item_id: item(%{name: "7.62 PS"}).id, caliber: "Caliber762x39"})

      %{rounds: Ammo.list_rounds()}
    end

    test "matches the round's name or its caliber label", %{rounds: rounds} do
      assert [%{item: %{name: "7.62 PS"}}] = Ammo.filter(rounds, "7.62 PS")
      # caliber label search ("5.56x45mm NATO")
      assert [%{caliber: "Caliber556x45NATO"}] = Ammo.filter(rounds, "5.56x45")
    end

    test "a blank or nil query keeps every round", %{rounds: rounds} do
      assert length(Ammo.filter(rounds, "  ")) == 2
      assert length(Ammo.filter(rounds, nil)) == 2
    end
  end

  describe "group/2" do
    test "orders caliber blocks by display order and sorts within each block" do
      pistol = item(%{name: "9mm round"})
      rifle_hi = item(%{name: "Rifle HI"})
      rifle_lo = item(%{name: "Rifle LO"})

      ammo_round(%{item_id: pistol.id, caliber: "Caliber9x19PARA", damage: 60})

      ammo_round(%{
        item_id: rifle_hi.id,
        caliber: "Caliber556x45NATO",
        damage: 55,
        penetration_power: 40
      })

      ammo_round(%{
        item_id: rifle_lo.id,
        caliber: "Caliber556x45NATO",
        damage: 45,
        penetration_power: 20
      })

      groups = Ammo.group(Ammo.list_rounds(), :default)

      # Pistol caliber sorts before the rifle caliber.
      assert [{"Caliber9x19PARA", _, _}, {"Caliber556x45NATO", _, rifle_rows}] = groups
      # Default sort = penetration desc within the block.
      assert Enum.map(rifle_rows, & &1.penetration_power) == [40, 20]

      # Ascending damage sort flips the within-block order.
      [_, {"Caliber556x45NATO", _, asc_rows}] = Ammo.group(Ammo.list_rounds(), :damage_asc)
      assert Enum.map(asc_rows, & &1.damage) == [45, 55]
    end
  end
end
