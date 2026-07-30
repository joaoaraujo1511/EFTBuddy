defmodule EftBuddyWeb.MapsLive.MarkersTest do
  @moduledoc """
  The spawn-point marker model.

  Boss pins used to be one per spawn *zone*, anchored at the zone's first
  position — which is why Customs rendered 5 boss pins where tarkov.dev renders
  29, and why five of Terminal's bosses stacked on a single coordinate. These
  cases pin the model that replaced it: one pin per physical spawn point,
  joined on the raw `spawn_key`.
  """
  use ExUnit.Case, async: true

  alias EftBuddyWeb.MapsLive.Markers

  defp spawn_point(attrs) do
    Map.merge(
      %{
        spawn_type: "boss",
        zone_name: "ZoneDormitory",
        sides: ["scav"],
        categories: ["bot", "boss"],
        pos_x: 0.0,
        pos_y: 0.0,
        pos_z: 0.0
      },
      attrs
    )
  end

  defp boss(name, slug, keys) do
    %{
      name: name,
      normalized_name: slug,
      spawn_locations: Enum.map(keys, &%{"spawn_key" => &1, "name" => &1, "positions" => []})
    }
  end

  # Only the associations `build/1` touches; everything else is empty.
  defp game_map(attrs) do
    Map.merge(
      %{
        extracts: [],
        locks: [],
        hazards: [],
        transits: [],
        spawns: [],
        bosses: [],
        loot_containers: [],
        stationary_weapons: [],
        switches: [],
        bounds: nil
      },
      attrs
    )
  end

  defp types(markers), do: Enum.map(markers, & &1["type"])

  describe "one pin per physical spawn point" do
    # The regression that made Customs 5 instead of 29: Reshala alone has 7
    # positions in Dorms, 9 in New Gas Station and 13 in Stronghold.
    test "three spawn rows in one zone produce three pins" do
      markers =
        Markers.build(
          game_map(%{
            bosses: [boss("Reshala", "reshala", ["ZoneDormitory"])],
            spawns: [
              spawn_point(%{pos_x: 1.0}),
              spawn_point(%{pos_x: 2.0}),
              spawn_point(%{pos_x: 3.0})
            ]
          })
        )

      assert length(markers) == 3
      assert types(markers) == List.duplicate("spawn_boss", 3)
      assert Enum.map(markers, & &1["x"]) == [1.0, 2.0, 3.0]
    end

    test "spawn points with no usable coordinates are skipped" do
      markers =
        Markers.build(
          game_map(%{
            bosses: [boss("Reshala", "reshala", ["ZoneDormitory"])],
            spawns: [spawn_point(%{pos_x: nil}), spawn_point(%{pos_z: nil})]
          })
        )

      assert markers == []
    end
  end

  describe "the boss join uses the raw spawn_key" do
    # The adapter translates `name` for display ("ZoneDormitory" -> "Dorms"),
    # which destroyed the join key until `spawnKey` was synced alongside it.
    test "matches the raw key, not the translated display name" do
      bosses = [
        %{
          name: "Reshala",
          normalized_name: "reshala",
          spawn_locations: [
            %{"spawn_key" => "ZoneDormitory", "name" => "Dorms", "positions" => []}
          ]
        }
      ]

      matched =
        Markers.build(game_map(%{bosses: bosses, spawns: [spawn_point(%{})]}))

      assert types(matched) == ["spawn_boss"]

      # A spawn whose zone is the *display* name must not match.
      unmatched =
        Markers.build(game_map(%{bosses: bosses, spawns: [spawn_point(%{zone_name: "Dorms"})]}))

      assert types(unmatched) == ["spawn_scav"]
    end

    test "a boss location with no spawn_key claims nothing" do
      bosses = [
        %{
          name: "Reshala",
          normalized_name: "reshala",
          spawn_locations: [%{"spawn_key" => nil, "name" => "Dorms", "positions" => []}]
        }
      ]

      assert types(Markers.build(game_map(%{bosses: bosses, spawns: [spawn_point(%{})]}))) ==
               ["spawn_scav"]
    end
  end

  describe "boss-category points no boss claims" do
    # 391 points across the roster — 164 on Streets alone — were rendered as
    # boss spawns purely because the API tags them `boss`.
    test "a bot+scav point becomes a scav spawn" do
      markers = Markers.build(game_map(%{spawns: [spawn_point(%{})]}))

      assert types(markers) == ["spawn_scav"]
      assert Enum.map(markers, & &1["label"]) == ["Scav spawn"]
    end

    test "a point that is neither bot nor scav is dropped entirely" do
      markers =
        Markers.build(game_map(%{spawns: [spawn_point(%{sides: ["pmc"], categories: ["boss"]})]}))

      assert markers == []
    end

    test "a sniper-category point becomes a sniper scav" do
      markers =
        Markers.build(
          game_map(%{spawns: [spawn_point(%{categories: ["bot", "boss", "sniper"]})]})
        )

      assert types(markers) == ["spawn_sniper_scav"]
    end

    # Rows written before `sides`/`categories` existed read back as [].
    test "a point with no sides or categories degrades to no marker, not a crash" do
      markers =
        Markers.build(game_map(%{spawns: [spawn_point(%{sides: [], categories: []})]}))

      assert markers == []
    end
  end

  describe "points shared by several bosses" do
    # Terminal's Zone2ScavPort29 hosts Glukhar, Killa, Reshala, Sanitar and
    # Tagilla. All five are generic bosses, so they share one pin.
    test "bosses on the same layer share one pin naming all of them" do
      markers =
        Markers.build(
          game_map(%{
            bosses: [
              boss("Glukhar", "glukhar", ["2ScavPort29"]),
              boss("Killa", "killa", ["2ScavPort29"])
            ],
            spawns: [spawn_point(%{zone_name: "2ScavPort29"})]
          })
        )

      assert [%{"type" => "spawn_boss", "label" => "Glukhar, Killa"}] = markers
    end

    # Factory's BotZone hosts Tagilla and the Cultist Priest on the same five
    # positions. Collapsing them into one generic pin hid the cultist entirely.
    test "bosses on different layers each get their own pin at the same point" do
      markers =
        Markers.build(
          game_map(%{
            bosses: [
              boss("Tagilla", "tagilla", ["BotZone"]),
              boss("Cultist Priest", "cultist-priest", ["BotZone"])
            ],
            spawns: [spawn_point(%{zone_name: "BotZone", pos_x: 7.0, pos_z: 9.0})]
          })
        )

      assert [
               %{"type" => "spawn_boss", "label" => "Tagilla", "x" => 7.0, "z" => 9.0},
               %{"type" => "spawn_cultist", "label" => "Cultist Priest", "x" => 7.0, "z" => 9.0}
             ] = markers
    end

    # Customs' ZoneScavBase: Reshala + Cultist Priest + Knight, 13 points.
    test "a three-way split yields three pins in panel order" do
      markers =
        Markers.build(
          game_map(%{
            bosses: [
              boss("Reshala", "reshala", ["ZoneScavBase"]),
              boss("Cultist Priest", "cultist-priest", ["ZoneScavBase"]),
              boss("Knight", "knight", ["ZoneScavBase"])
            ],
            spawns: [spawn_point(%{zone_name: "ZoneScavBase"})]
          })
        )

      assert types(markers) == ["spawn_boss", "spawn_cultist", "spawn_goons"]
    end

    test "a boss listed twice for one zone is named once" do
      markers =
        Markers.build(
          game_map(%{
            bosses: [
              boss("Tagilla", "tagilla", ["BotZone"]),
              boss("Tagilla", "tagilla", ["BotZone"])
            ],
            spawns: [spawn_point(%{zone_name: "BotZone"})]
          })
        )

      assert [%{"type" => "spawn_boss", "label" => "Tagilla"}] = markers
    end
  end

  describe "the four boss layers" do
    for {slug, name, type} <- [
          {"cultist-priest", "Cultist Priest", "spawn_cultist"},
          {"rogue", "Rogue", "spawn_rogue"},
          {"knight", "Knight", "spawn_goons"},
          {"reshala", "Reshala", "spawn_boss"},
          {"glukhar", "Glukhar", "spawn_boss"}
        ] do
      test "#{slug} renders on #{type}" do
        markers =
          Markers.build(
            game_map(%{
              bosses: [boss(unquote(name), unquote(slug), ["ZoneDormitory"])],
              spawns: [spawn_point(%{})]
            })
          )

        assert types(markers) == [unquote(type)]
      end
    end

    test "a boss with no normalized name falls back to the generic layer" do
      bosses = [
        %{
          name: "Mystery",
          normalized_name: nil,
          spawn_locations: [%{"spawn_key" => "ZoneDormitory", "positions" => []}]
        }
      ]

      assert types(Markers.build(game_map(%{bosses: bosses, spawns: [spawn_point(%{})]}))) ==
               ["spawn_boss"]
    end
  end

  describe "The Labyrinth" do
    # Its only boss carries zero spawn locations, so none of its nine
    # boss-category points is a boss spawn. We used to label all nine "Shadow of
    # Tagilla spawn", asserting something the data never said.
    test "a boss with no spawn locations produces scav pins, not boss pins" do
      spawns = for i <- 1..9, do: spawn_point(%{pos_x: i * 1.0})

      markers =
        Markers.build(
          game_map(%{
            bosses: [
              %{name: "Shadow of Tagilla", normalized_name: "tagilla", spawn_locations: []}
            ],
            spawns: spawns
          })
        )

      assert length(markers) == 9
      assert Enum.uniq(types(markers)) == ["spawn_scav"]
    end
  end

  describe "the bounds filter" do
    # tarkov.dev's positionIsInBounds, on raw game coordinates.
    defp bounded(x, z, bounds) do
      Markers.build(
        game_map(%{
          bounds: bounds,
          spawns: [spawn_point(%{spawn_type: "pmc", pos_x: x, pos_z: z})]
        })
      )
    end

    test "a point outside the box is dropped" do
      assert bounded(500.0, 0.0, [[-100.0, -100.0], [100.0, 100.0]]) == []
    end

    test "a point inside the box is kept" do
      assert [%{"type" => "spawn_pmc"}] = bounded(0.0, 0.0, [[-100.0, -100.0], [100.0, 100.0]])
    end

    test "a point exactly on the edge is kept" do
      assert [_] = bounded(100.0, 100.0, [[-100.0, -100.0], [100.0, 100.0]])
    end

    # Factory's bounds are [[77, -64.5], [-65.5, 67.4]] — corner order is not
    # guaranteed, so the test has to be min/max, not a fixed-corner comparison.
    test "reversed corner order behaves identically" do
      assert [_] = bounded(0.0, 0.0, [[100.0, 100.0], [-100.0, -100.0]])
      assert bounded(500.0, 0.0, [[100.0, 100.0], [-100.0, -100.0]]) == []
    end

    test "a map with no bounds keeps everything" do
      assert [_] = bounded(9_999.0, 9_999.0, nil)
    end
  end

  describe "descriptors/1" do
    defp descriptors_for(markers), do: Markers.descriptors(markers)

    test "only types actually present are described" do
      descriptors = descriptors_for([%{"type" => "spawn_pmc"}])

      assert Enum.map(descriptors, & &1["type"]) == ["spawn_pmc"]
    end

    test "catalog order is preserved regardless of marker order" do
      descriptors =
        descriptors_for([%{"type" => "spawn_pmc"}, %{"type" => "lock"}, %{"type" => "transit"}])

      assert Enum.map(descriptors, & &1["type"]) == ["transit", "lock", "spawn_pmc"]
    end

    test "the faction layers sit directly under the generic boss layer" do
      markers = [
        %{"type" => "switch"},
        %{"type" => "spawn_goons"},
        %{"type" => "spawn_boss"},
        %{"type" => "spawn_cultist"},
        %{"type" => "spawn_rogue"}
      ]

      assert Enum.map(descriptors_for(markers), & &1["type"]) == [
               "spawn_boss",
               "spawn_cultist",
               "spawn_rogue",
               "spawn_goons",
               "switch"
             ]
    end

    # A map with no rogues must not offer a Rogues toggle.
    test "a layer with no markers is not described" do
      types = descriptors_for([%{"type" => "spawn_boss"}]) |> Enum.map(& &1["type"])

      assert types == ["spawn_boss"]
    end

    test "each boss layer carries its own label and art" do
      for {type, label, icon} <- [
            {"spawn_boss", "Boss spawns", "spawn_boss.webp"},
            {"spawn_cultist", "Cultist Priest", "spawn_cultist.webp"},
            {"spawn_rogue", "Rogues", "spawn_rogue.webp"},
            {"spawn_goons", "The Goons", "spawn_goons.webp"}
          ] do
        [d] = descriptors_for([%{"type" => type}])

        assert d["label"] == label
        assert d["icon"] == "/images/maps/markers/#{icon}"
      end
    end

    test "hidden is always present, and spawn layers default off" do
      [spawn] = descriptors_for([%{"type" => "spawn_scav"}])
      [extract] = descriptors_for([%{"type" => "extract_pmc"}])

      assert spawn["hidden"] == true
      assert extract["hidden"] == false
    end
  end

  describe "the catalog's art" do
    # The scav layer once pointed at `scav.webp` after that asset was renamed to
    # `spawn_scav.webp`, and nothing caught it — the toggle just rendered a
    # broken image. Every declared icon has to exist on disk.
    test "every layer's icon file exists" do
      dir = Path.join(:code.priv_dir(:eft_buddy), "static/images/maps/markers")

      missing =
        for entry <- Markers.catalog(),
            not File.exists?(Path.join(dir, entry.icon)),
            do: {entry.type, entry.icon}

      assert missing == []
    end

    test "every layer declares a type, a label and an icon" do
      for entry <- Markers.catalog() do
        assert is_binary(entry.type) and entry.type != ""
        assert is_binary(entry.label) and entry.label != ""
        assert is_binary(entry.icon) and String.ends_with?(entry.icon, ".webp")
      end
    end

    test "layer types are unique" do
      types = Enum.map(Markers.catalog(), & &1.type)
      assert types == Enum.uniq(types)
    end
  end

  describe "locks" do
    # `lock_label/1` was the only place needs_power surfaced, and it was
    # unreachable whenever the key item was known — so a powered keyed door
    # showed just the key name.
    test "a powered keyed door warns about the power as well as naming the key" do
      lock = %{
        key_item: %{name: "RB-BK marked key"},
        needs_power: true,
        lock_type: "door",
        pos_x: 0.0,
        pos_y: 0.0,
        pos_z: 0.0
      }

      assert [%{"label" => "RB-BK marked key (needs power)"}] =
               Markers.build(game_map(%{locks: [lock]}))
    end

    test "an unkeyed lock still describes itself" do
      lock = %{
        key_item: nil,
        needs_power: false,
        lock_type: "door",
        pos_x: 0.0,
        pos_y: 0.0,
        pos_z: 0.0
      }

      assert [%{"label" => "Door"}] = Markers.build(game_map(%{locks: [lock]}))
    end
  end
end
