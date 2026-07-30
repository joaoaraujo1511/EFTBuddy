defmodule EftBuddy.MapsTest do
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Fixtures
  alias EftBuddy.Maps

  defp slugs(maps), do: Enum.map(maps, & &1.normalized_name)

  describe "visible?/1 — imagery gate" do
    test "a map with an interactive base is visible" do
      assert Maps.visible?(Fixtures.game_map(%{normalized_name: "customs"}))
    end

    test "a map with no interactive base but a flat render is visible" do
      map =
        Fixtures.game_map(%{
          normalized_name: "future-map",
          projection: nil,
          transform: nil,
          bounds: nil,
          image_variants: %{"2d" => [%{"url" => "https://example.test/x.jpg"}]}
        })

      assert Maps.visible?(map)
    end

    # This is what replaced the hand-maintained allowlist: a location upstream
    # hasn't drawn art for yet stays hidden with no code change, and reappears
    # on its own once art exists.
    test "a map with no imagery at all is hidden" do
      map =
        Fixtures.game_map(%{
          normalized_name: "ground-zero-tutorial",
          projection: nil,
          transform: nil,
          bounds: nil,
          image_variants: %{}
        })

      refute Maps.visible?(map)
    end

    test "a blacklisted map is hidden even with full imagery" do
      refute Maps.visible?(Fixtures.game_map(%{normalized_name: "the-lab-dark"}))
      refute Maps.visible?(Fixtures.game_map(%{normalized_name: "night-factory"}))
      refute Maps.visible?(Fixtures.game_map(%{normalized_name: "ground-zero-21"}))
    end
  end

  describe "list_maps/1" do
    test "excludes blacklisted and imageless maps, ordered by name" do
      Fixtures.game_map(%{name: "Woods", normalized_name: "woods"})
      Fixtures.game_map(%{name: "Customs", normalized_name: "customs"})
      Fixtures.game_map(%{name: "Night Factory", normalized_name: "night-factory"})

      Fixtures.game_map(%{
        name: "Tutorial",
        normalized_name: "ground-zero-tutorial",
        projection: nil,
        transform: nil,
        bounds: nil
      })

      assert slugs(Maps.list_maps()) == ["customs", "woods"]
    end
  end

  describe "get_map_by_slug/1" do
    test "returns a visible map with its detail associations loaded" do
      map = Fixtures.game_map(%{normalized_name: "the-lab"})
      Fixtures.map_boss(%{map_id: map.id, name: "Raider"})

      found = Maps.get_map_by_slug("the-lab")

      assert found.id == map.id
      assert is_list(found.variants)
      assert [%{name: "Raider"}] = found.bosses
    end

    test "returns nil for a blacklisted slug" do
      Fixtures.game_map(%{normalized_name: "the-lab-dark"})
      refute Maps.get_map_by_slug("the-lab-dark")
    end

    test "returns nil for an imageless map" do
      Fixtures.game_map(%{
        normalized_name: "artless",
        projection: nil,
        transform: nil,
        bounds: nil
      })

      refute Maps.get_map_by_slug("artless")
    end

    test "returns nil for a non-binary slug" do
      refute Maps.get_map_by_slug(nil)
    end
  end

  # Variant slugs resolve onto their canonical map so task references to them
  # are re-pointed rather than dropped. Before this, `night-factory`'s 59
  # objective references and `ground-zero-21`'s 37 vanished, understating both
  # maps' quest badges.
  describe "alias_slug/1" do
    test "maps raid variants onto their canonical map" do
      assert Maps.alias_slug("night-factory") == "factory"
      assert Maps.alias_slug("ground-zero-21") == "ground-zero"
    end

    test "leaves canonical slugs untouched" do
      assert Maps.alias_slug("customs") == "customs"
    end

    test "does not alias the tutorial, which is not a raid on the map" do
      assert Maps.alias_slug("ground-zero-tutorial") == "ground-zero-tutorial"
    end
  end

  describe "excluded_slugs/0" do
    test "covers both the blacklist and the never-seeded tutorial" do
      excluded = Maps.excluded_slugs()

      for slug <- ~w(night-factory ground-zero-21 the-lab-dark ground-zero-tutorial) do
        assert slug in excluded, "expected #{slug} to be excluded from seeding"
      end
    end
  end

  describe "quest_counts/0" do
    test "counts a map's primary tasks and objective references without double-counting" do
      map = Fixtures.game_map(%{normalized_name: "customs"})
      other = Fixtures.game_map(%{normalized_name: "woods"})

      # A task whose primary map is customs, and which also has an objective there.
      primary = Fixtures.task(%{map_id: map.id})
      obj = Fixtures.objective(%{task_id: primary.id})
      Repo.insert!(%EftBuddy.Tasks.ObjectiveMap{objective_id: obj.id, map_id: map.id})

      # A task that only touches customs via an objective.
      via = Fixtures.task(%{map_id: other.id})
      obj2 = Fixtures.objective(%{task_id: via.id})
      Repo.insert!(%EftBuddy.Tasks.ObjectiveMap{objective_id: obj2.id, map_id: map.id})

      counts = Maps.quest_counts()

      assert counts[map.id] == 2
      assert counts[other.id] == 1
    end

    test "a map with no tasks is simply absent" do
      map = Fixtures.game_map(%{normalized_name: "customs"})
      refute Map.has_key?(Maps.quest_counts(), map.id)
    end
  end

  describe "group_bosses/1" do
    # `map_bosses` is one row per spawn *entry*: The Lab's raiders are 16 rows,
    # Icebreaker's five bosses 40. The index card iterated them raw and rendered
    # one chip each.
    test "many entries of one boss collapse to a single group" do
      map = Fixtures.game_map(%{normalized_name: "the-lab"})

      for i <- 1..16 do
        Fixtures.map_boss(%{
          map_id: map.id,
          external_id: "raider-#{i}",
          name: "Raider",
          normalized_name: "raider"
        })
      end

      [loaded] = Maps.list_maps()

      assert length(loaded.bosses) == 16
      assert [%{name: "Raider"}] = Maps.group_bosses(loaded.bosses)
    end

    # The grouping promises "first appearance" order, which only means anything
    # if the preload is ordered — `map_bosses` has no ordinal column, so an
    # unordered preload returns Postgres heap order.
    test "the preload order is stable, so the headline boss stays first" do
      map = Fixtures.game_map(%{normalized_name: "customs"})

      roster = [{"Reshala", "reshala"}, {"Partisan", "partisan"}, {"Cultist", "cult"}]

      # Inserted back to front, so a passing assertion can only come from
      # `position` — not from insertion or heap order.
      for {{name, slug}, i} <- Enum.with_index(roster) |> Enum.reverse() do
        Fixtures.map_boss(%{
          map_id: map.id,
          external_id: slug,
          name: name,
          normalized_name: slug,
          position: i
        })
      end

      [loaded] = Maps.list_maps()
      detail = Maps.get_map_by_slug("customs")

      assert Enum.map(Maps.group_bosses(loaded.bosses), & &1.name) ==
               ["Reshala", "Partisan", "Cultist"]

      assert Enum.map(Maps.group_bosses(detail.bosses), & &1.name) ==
               ["Reshala", "Partisan", "Cultist"]
    end
  end
end
