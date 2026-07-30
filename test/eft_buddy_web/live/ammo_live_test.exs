defmodule EftBuddyWeb.AmmoLiveTest do
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  alias EftBuddy.Ammo.Round
  alias EftBuddy.Armor.Plate
  alias EftBuddy.Repo

  defp round(item, attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      external_id: "ammo-#{n}",
      item_id: item.id,
      caliber: "Caliber556x45NATO",
      ammo_type: "bullet",
      damage: 54,
      penetration_power: 31,
      penetration_chance: 0.5,
      armor_damage: 37,
      ricochet_chance: 0.4,
      accuracy_modifier: 0.0,
      recoil_modifier: 0.0,
      initial_speed: 922.0,
      projectile_count: 1,
      light_bleed_modifier: 0.0,
      heavy_bleed_modifier: 0.0,
      stack_max_size: 60,
      tracer: false,
      tracer_color: "red"
    }

    Repo.insert!(struct(Round, Map.merge(defaults, Map.new(attrs))))
  end

  test "renders the caliber label and round name", %{conn: conn} do
    item = item(%{name: "5.56x45mm M855"})
    round(item, %{caliber: "Caliber556x45NATO"})

    {:ok, _view, html} = live(conn, "/ammo")

    assert html =~ "Ballistics"
    assert html =~ "5.56x45mm NATO"
    assert html =~ "5.56x45mm M855"
  end

  test "shows the shared standby state when no ammo is synced", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/ammo")
    assert html =~ "Standby"
    assert html =~ "Data is loading in the background"
  end

  test "search filters rounds by name", %{conn: conn} do
    a = item(%{name: "5.56x45mm M855"})
    b = item(%{name: "7.62x39mm PS"})
    round(a, %{caliber: "Caliber556x45NATO"})
    round(b, %{caliber: "Caliber762x39"})

    {:ok, view, html} = live(conn, "/ammo")
    assert html =~ "5.56x45mm M855"
    assert html =~ "7.62x39mm PS"

    filtered =
      view
      |> form("#global-search", query: "M855")
      |> render_change()

    assert filtered =~ "5.56x45mm M855"
    refute filtered =~ "7.62x39mm PS"
  end

  test "the plates view switch reveals plate rows with material columns", %{conn: conn} do
    it = item(%{name: "ESAPI level IV ballistic plate"})

    Repo.insert!(%Plate{
      external_id: "p1",
      item_id: it.id,
      class: 6,
      durability: 55,
      material: "Ceramic",
      armor_type: "Heavy",
      blunt_throughput: 0.3,
      speed_penalty: -0.015,
      turn_penalty: -0.005,
      ergo_penalty: -0.015,
      repair_cost: 335
    })

    {:ok, view, html} = live(conn, "/ammo")

    # The Plates view switch is always visible, but the ammo view shows first.
    assert html =~ "Armor Plates"
    refute html =~ "ESAPI level IV"

    shown = render_click(element(view, "button[phx-value-filter='plates']"))
    assert shown =~ "ESAPI level IV"
    assert shown =~ "Class 6"
    # Destructibility / Explosive now render as per-plate columns (joined by
    # material), alongside the material label.
    assert shown =~ "Destructibility"
    assert shown =~ "Explosive"
    assert shown =~ "Ceramic"
  end

  test "plate columns are sortable within a class", %{conn: conn} do
    tough = item(%{name: "Tough plate"})
    weak = item(%{name: "Weak plate"})

    # Same class; different raw durability so a durability sort reorders them.
    Repo.insert!(%Plate{
      external_id: "tough",
      item_id: tough.id,
      class: 5,
      durability: 60,
      material: "Ceramic",
      armor_type: "Heavy",
      blunt_throughput: 0.3,
      speed_penalty: -0.02,
      turn_penalty: -0.01,
      ergo_penalty: -0.01,
      repair_cost: 300
    })

    Repo.insert!(%Plate{
      external_id: "weak",
      item_id: weak.id,
      class: 5,
      durability: 30,
      material: "Ceramic",
      armor_type: "Heavy",
      blunt_throughput: 0.3,
      speed_penalty: -0.02,
      turn_penalty: -0.01,
      ergo_penalty: -0.01,
      repair_cost: 100
    })

    {:ok, view, _html} = live(conn, "/ammo")
    render_click(element(view, "button[phx-value-filter='plates']"))

    # The shared search box stays present in the plates view and filters plates.
    # It is the ONE global search box in the page header (`UI.search` rendered
    # by `Layouts.app`, id `global-search`), not a per-page form.
    searched =
      view
      |> form("#global-search", query: "Weak")
      |> render_change()

    assert searched =~ "Weak plate"
    refute searched =~ "Tough plate"

    # Clear the search before exercising the sort.
    view |> form("#global-search", query: "") |> render_change()

    # Ascending durability sort puts the weaker (30) plate before the tough (60) one.
    asc =
      render_click(
        element(view, "button[phx-click='toggle_plates_sort'][phx-value-col='durability']")
      )

    assert plate_order(asc) == ["Weak plate", "Tough plate"]

    # Clicking again flips to descending.
    desc =
      render_click(
        element(view, "button[phx-click='toggle_plates_sort'][phx-value-col='durability']")
      )

    assert plate_order(desc) == ["Tough plate", "Weak plate"]
  end

  # First-appearance order of the two named plates in the rendered HTML.
  defp plate_order(html) do
    ["Tough plate", "Weak plate"]
    |> Enum.map(fn name -> {name, :binary.match(html, name)} end)
    |> Enum.filter(fn {_name, match} -> match != :nomatch end)
    |> Enum.sort_by(fn {_name, {pos, _len}} -> pos end)
    |> Enum.map(&elem(&1, 0))
  end

  describe "pen_rating/3 (NoFoodAfterMidnight tiers, calibrated to eft-ammo/wiki)" do
    alias EftBuddyWeb.AmmoLive.Index

    test "M855A1 (pen 44) matches the wiki row 6/6/6/6/5/4" do
      assert Enum.map(1..6, &Index.pen_rating(44, "bullet", &1)) == [6, 6, 6, 6, 5, 4]
    end

    test "top-tier rounds max out and weak rounds bottom out" do
      # M61 (pen 60) shreds every class
      assert Enum.map(1..6, &Index.pen_rating(60, "bullet", &1)) == [6, 6, 6, 6, 6, 6]
      # a pistol round (pen 15) is useless against high armor
      assert Index.pen_rating(15, "bullet", 6) == 0
    end

    test "true buckshot is a flat 3 across all classes" do
      assert Enum.map(1..6, &Index.pen_rating(2, "buckshot", &1)) == [3, 3, 3, 3, 3, 3]
      # high-pen 'buckshot' (flechette) is NOT flattened
      refute Index.pen_rating(31, "buckshot", 1) == 3
    end

    test "labels the tiers" do
      assert Index.rating_label(0) == "Pointless"
      assert Index.rating_label(4) == "Effective"
      assert Index.rating_label(6) == "Usually ignores"
    end
  end
end
