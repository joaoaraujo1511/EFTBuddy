defmodule EftBuddy.AmmoTest do
  use EftBuddy.DataCase, async: true

  import EftBuddy.Fixtures

  alias EftBuddy.Ammo
  alias EftBuddy.Ammo.Round
  alias EftBuddy.Items.BuyFor

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

  defp buy_for(item, vendor, attrs \\ %{}) do
    Repo.insert!(
      struct(
        BuyFor,
        Map.merge(
          %{
            price: 100,
            price_rub: 100,
            currency: "RUB",
            game_mode: "regular",
            item_id: item.id,
            vendor_id: vendor.id
          },
          Map.new(attrs)
        )
      )
    )
  end

  describe "list_rounds/0 source derivation" do
    test "flags trader, flea, barter and craft availability from the linked item" do
      it = item(%{name: "5.56x45mm M855"})

      buy_for(it, vendor(%{name: "Prapor", normalized_name: "prapor"}))
      buy_for(it, vendor(%{name: "Flea Market", normalized_name: "flea-market"}))

      b = barter(%{trader_id: trader().id})
      barter_reward(%{barter_id: b.id, item_id: it.id})

      sl = station_level(%{station_id: station().id})
      c = craft(%{station_level_id: sl.id})
      craft_reward(%{craft_id: c.id, item_id: it.id})

      ammo_round(%{item_id: it.id})

      [enriched] = Ammo.list_rounds()

      assert Enum.sort(enriched.sources) == ["barter", "craft", "flea", "trader"]
    end

    test "a round with no availability rows has empty sources" do
      it = item(%{name: "Orphan round"})
      ammo_round(%{item_id: it.id})

      [enriched] = Ammo.list_rounds()
      assert enriched.sources == []
    end

    test "does not flag trader for a PVE-only buy offer (single regular-mode view)" do
      it = item(%{name: "PVE only"})
      buy_for(it, vendor(%{name: "Prapor", normalized_name: "prapor"}), %{game_mode: "pve"})
      ammo_round(%{item_id: it.id})

      [enriched] = Ammo.list_rounds()
      assert enriched.sources == []
    end
  end

  describe "filter/2" do
    setup do
      item_a = item(%{name: "5.56 M855"})
      item_b = item(%{name: "7.62 PS"})
      buy_for(item_a, vendor(%{name: "Flea Market", normalized_name: "flea-market"}))

      ammo_round(%{item_id: item_a.id, caliber: "Caliber556x45NATO"})
      ammo_round(%{item_id: item_b.id, caliber: "Caliber762x39"})

      %{rounds: Ammo.list_rounds()}
    end

    test "by caliber", %{rounds: rounds} do
      filtered = Ammo.filter(rounds, %{caliber: "Caliber556x45NATO"})
      assert length(filtered) == 1
      assert hd(filtered).caliber == "Caliber556x45NATO"
    end

    test "by source", %{rounds: rounds} do
      flea = Ammo.filter(rounds, %{source: "flea"})
      assert length(flea) == 1
      assert hd(flea).item.name == "5.56 M855"

      assert Ammo.filter(rounds, %{source: "craft"}) == []
    end

    test "by search query on name and caliber label", %{rounds: rounds} do
      assert [%{item: %{name: "7.62 PS"}}] = Ammo.filter(rounds, %{query: "7.62 PS"})
      # caliber label search ("5.56x45mm NATO")
      assert [%{caliber: "Caliber556x45NATO"}] = Ammo.filter(rounds, %{query: "5.56x45"})
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

  describe "source_counts/2" do
    test "counts per source honoring the caliber context" do
      it = item(%{name: "Round A"})
      buy_for(it, vendor(%{name: "Prapor", normalized_name: "prapor"}))
      ammo_round(%{item_id: it.id, caliber: "Caliber556x45NATO"})
      ammo_round(%{item_id: item().id, caliber: "Caliber762x39"})

      counts = Ammo.source_counts(Ammo.list_rounds(), %{caliber: "all"})
      assert counts["all"] == 2
      assert counts["trader"] == 1
      assert counts["flea"] == 0

      scoped = Ammo.source_counts(Ammo.list_rounds(), %{caliber: "Caliber762x39"})
      assert scoped["all"] == 1
      assert scoped["trader"] == 0
    end
  end

  describe "calibers_present/1" do
    test "returns distinct calibers in display order with labels" do
      ammo_round(%{item_id: item().id, caliber: "Caliber12g"})
      ammo_round(%{item_id: item().id, caliber: "Caliber9x19PARA"})
      ammo_round(%{item_id: item().id, caliber: "Caliber9x19PARA"})

      assert [{"Caliber9x19PARA", "9x19mm Parabellum"}, {"Caliber12g", "12/70"}] =
               Ammo.calibers_present(Ammo.list_rounds())
    end
  end
end
