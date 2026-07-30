defmodule EftBuddy.Maps.SyncTest do
  @moduledoc """
  Pure normalisation functions from the maps sync pipeline.

  These are the ones with tricky, previously-buggy semantics: the boss-zone
  join key, the spawn classifier's ordering, and the Ground Zero rebase.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Maps.Sync

  describe "normalize_spawn_locations/1" do
    test "keeps the raw spawn_key alongside the translated display name" do
      assert [loc] =
               Sync.normalize_spawn_locations([
                 %{
                   "spawnKey" => "ZoneDormitory",
                   "name" => "Dorms",
                   "chance" => 1,
                   "positions" => []
                 }
               ])

      assert loc["spawn_key"] == "ZoneDormitory"
      assert loc["name"] == "Dorms"
      assert loc["chance"] == 1.0
    end

    test "a zone repeated across merged entries is kept once" do
      locs =
        Sync.normalize_spawn_locations([
          %{"spawnKey" => "ZoneDormitory", "name" => "Dorms", "positions" => []},
          %{"spawnKey" => "ZoneDormitory", "name" => "Dorms", "positions" => []}
        ])

      assert length(locs) == 1
    end

    # The dedupe used to key on the *translated* name, so two genuinely
    # different zones that happen to translate alike collapsed into one and the
    # second zone's spawn points were silently orphaned.
    test "distinct keys that translate to the same name both survive" do
      locs =
        Sync.normalize_spawn_locations([
          %{"spawnKey" => "ZoneDormitory", "name" => "Dorms", "positions" => []},
          %{"spawnKey" => "ZoneDormsUpper", "name" => "Dorms", "positions" => []}
        ])

      assert Enum.map(locs, & &1["spawn_key"]) == ["ZoneDormitory", "ZoneDormsUpper"]
    end

    test "positions without usable planar coordinates are dropped" do
      assert [%{"positions" => [%{"x" => 1.0, "y" => 2.0, "z" => 3.0}]}] =
               Sync.normalize_spawn_locations([
                 %{
                   "spawnKey" => "Z",
                   "positions" => [
                     %{"x" => 1, "y" => 2, "z" => 3},
                     %{"x" => nil, "y" => 2, "z" => 3}
                   ]
                 }
               ])
    end

    test "a missing list normalises to empty" do
      assert Sync.normalize_spawn_locations(nil) == []
    end
  end

  describe "classify_spawn/1" do
    test "the boss category wins outright" do
      assert Sync.classify_spawn(%{"categories" => ["bot", "boss"], "sides" => ["scav"]}) ==
               "boss"
    end

    # `sniper` had no case of its own, so nests fell through to the generic
    # scav branch and rendered as ordinary scav spawns.
    test "a sniper nest is classified before the generic scav case" do
      assert Sync.classify_spawn(%{"categories" => ["sniper"], "sides" => ["scav"]}) ==
               "sniper_scav"
    end

    test "a scav-side point is a scav spawn" do
      assert Sync.classify_spawn(%{"categories" => ["bot"], "sides" => ["scav"]}) == "scav"
    end

    test "player points are PMC, for either side spelling" do
      assert Sync.classify_spawn(%{"categories" => ["player"], "sides" => ["pmc"]}) == "pmc"
      assert Sync.classify_spawn(%{"categories" => ["player"], "sides" => ["all"]}) == "pmc"
    end

    test "anything else is not stored" do
      assert Sync.classify_spawn(%{"categories" => ["prop"], "sides" => []}) == nil
      assert Sync.classify_spawn(%{}) == nil
    end
  end

  describe "image_variants/1" do
    # Every flat render is separately authored, and almost never by the author
    # of the map's interactive base — so the viewer's per-render credit needs
    # the artist's own link, which the sync used to drop.
    test "a render carries its author and their link" do
      variants =
        Sync.image_variants([
          %{
            "key" => "customs-2d",
            "projection" => "2D",
            "author" => "monkimonkimonk",
            "authorLink" => "https://www.reddit.com/user/monkimonkimonk/"
          }
        ])

      assert %{"2d" => [v]} = variants
      assert v["author"] == "monkimonkimonk"
      assert v["author_link"] == "https://www.reddit.com/user/monkimonkimonk/"
      assert v["url"] =~ "customs-2d.jpg"
    end

    # Lighthouse's 2D is the one upstream entry that names an author without
    # giving a link. It must stay unlinked, not be sent somewhere invented.
    test "an author with no link yields nil rather than a guess" do
      assert %{"2d" => [v]} =
               Sync.image_variants([
                 %{
                   "key" => "lighthouse-2d",
                   "projection" => "2D",
                   "author" => "Shebuka & Jindouz"
                 }
               ])

      assert v["author"] == "Shebuka & Jindouz"
      assert v["author_link"] == nil
    end

    test "renders are grouped by projection and non-renders ignored" do
      variants =
        Sync.image_variants([
          %{"key" => "customs", "projection" => "interactive", "author" => "Shebuka"},
          %{"key" => "customs-2d", "projection" => "2D", "author" => "monkimonkimonk"},
          %{"key" => "customs-3d", "projection" => "3D", "author" => "re3mr"}
        ])

      assert Map.keys(variants) |> Enum.sort() == ["2d", "3d"]
    end
  end

  describe "boss_spawn_trigger/2" do
    # The API leaves the Cultist Priest's trigger null on every map it appears
    # on, so the night restriction is stamped in here. "Night only" alone didn't
    # tell a player whether their raid qualifies.
    test "the cultist priest gets its spawn window stated in game hours" do
      assert Sync.boss_spawn_trigger("cultist-priest", nil) == "Night only (22:00-07:00)"
    end

    test "a real trigger is never overwritten" do
      assert Sync.boss_spawn_trigger("cultist-priest", "Switch") == "Switch"
    end

    test "every other boss passes through untouched" do
      assert Sync.boss_spawn_trigger("reshala", nil) == nil

      assert Sync.boss_spawn_trigger("glukhar", "autoId_00000_D2_LEVER") ==
               "autoId_00000_D2_LEVER"
    end
  end

  describe "rebase/3" do
    # Ground Zero is built from the `ground-zero-21` payload but keeps the
    # canonical row's identity. The level bracket in the sibling's name leaked
    # onto the card as "Ground Zero 21+"; it is already visible through
    # min/max_player_level.
    test "identity and naming come from the canonical payload, everything else from the source" do
      source = %{
        "id" => "gz21",
        "normalizedName" => "ground-zero-21",
        "name" => "Ground Zero 21+",
        "description" => "For PMCs above level 20.",
        "bosses" => [:from_source]
      }

      canonical = %{
        "id" => "gz",
        "normalizedName" => "ground-zero",
        "name" => "Ground Zero",
        "description" => "A downtown district."
      }

      rebased = Sync.rebase(source, canonical, "ground-zero")

      assert rebased["id"] == "gz"
      assert rebased["normalizedName"] == "ground-zero"
      assert rebased["name"] == "Ground Zero"
      assert rebased["description"] == "A downtown district."
      assert rebased["bosses"] == [:from_source]
    end

    test "falls back to the source when the canonical payload has no name" do
      rebased = Sync.rebase(%{"name" => "Fallback"}, %{"id" => "x"}, "slug")
      assert rebased["name"] == "Fallback"
    end
  end

  # Every boss pin on every map hangs off `spawnKey` matching a spawn point's
  # `zoneName`. If upstream renames either side the join silently produces
  # nothing — no error, no crash, just empty boss layers everywhere. This turns
  # that into a failing test instead. Excluded by default (it hits the live
  # API); run with `mix test --include external`.
  @tag :external
  @tag timeout: 120_000
  test "upstream's boss spawn keys still intersect its spawn zone names" do
    {:ok, maps} = EftBuddy.TarkovApi.maps()

    orphaned =
      for m <- maps,
          keys =
            m["bosses"]
            |> List.wrap()
            |> Enum.flat_map(&List.wrap(&1["spawnLocations"]))
            |> MapSet.new(& &1["spawnKey"]),
          MapSet.size(keys) > 0,
          zones = MapSet.new(List.wrap(m["spawns"]), & &1["zoneName"]),
          MapSet.disjoint?(keys, zones) do
        m["normalizedName"]
      end

    assert orphaned == [],
           "these maps' boss spawn keys match no spawn zone, so their boss layers " <>
             "would render empty: #{inspect(orphaned)}"
  end
end
