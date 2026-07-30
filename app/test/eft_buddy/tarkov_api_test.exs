defmodule EftBuddy.TarkovApiTest do
  @moduledoc """
  The maps adapter's boss shaping.

  `boss_to_graphql/3` re-inflates a boss entry from `data.mobs` and translates
  its display strings. Two fields it used to drop are load-bearing: the raw
  `spawnKey` (the join to `map_spawns.zone_name`) and the escort portrait.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.TarkovApi

  @mobs %{
    "bossKojaniy" => %{
      "id" => "bossKojaniy",
      "name" => "Mob/Shturman",
      "normalizedName" => "shturman",
      "imagePortraitLink" => "https://example.test/shturman.png"
    },
    "followerKojaniy" => %{
      "id" => "followerKojaniy",
      "name" => "Mob/ShturmanGuard",
      "normalizedName" => "shturman-guard",
      "imagePortraitLink" => "https://example.test/shturman-guard.png"
    }
  }

  @locale %{
    "Mob/Shturman" => "Shturman",
    "Mob/ShturmanGuard" => "Shturman Guard",
    "ZoneSawMill" => "Sawmill"
  }

  defp entry(attrs \\ %{}) do
    Map.merge(
      %{
        "mob" => "bossKojaniy",
        "spawnChance" => 1,
        "spawnLocations" => [
          %{
            "spawnKey" => "ZoneSawMill",
            "name" => "ZoneSawMill",
            "chance" => 1,
            "positions" => []
          }
        ],
        "escorts" => [%{"mob" => "followerKojaniy", "amount" => [%{"count" => 2, "chance" => 1}]}]
      },
      attrs
    )
  end

  describe "spawn locations" do
    test "the raw join key survives while the display name is translated" do
      %{"spawnLocations" => [loc]} = TarkovApi.boss_to_graphql(entry(), @mobs, @locale)

      assert loc["spawnKey"] == "ZoneSawMill"
      assert loc["name"] == "Sawmill"
    end

    # Upstream exposes both, and both are raw — but the fallback has to read the
    # name *before* translation, or the key becomes "Sawmill" and matches no
    # spawn point.
    test "falls back to the untranslated name when spawnKey is absent" do
      entry =
        entry(%{
          "spawnLocations" => [%{"name" => "ZoneSawMill", "chance" => 1, "positions" => []}]
        })

      %{"spawnLocations" => [loc]} = TarkovApi.boss_to_graphql(entry, @mobs, @locale)

      assert loc["spawnKey"] == "ZoneSawMill"
      assert loc["name"] == "Sawmill"
    end
  end

  describe "escorts" do
    test "carry the portrait their own card needs" do
      %{"escorts" => [escort]} = TarkovApi.boss_to_graphql(entry(), @mobs, @locale)

      assert escort["boss"]["name"] == "Shturman Guard"
      assert escort["boss"]["normalizedName"] == "shturman-guard"
      assert escort["boss"]["imagePortraitLink"] == "https://example.test/shturman-guard.png"
      assert escort["amount"] == [%{"count" => 2, "chance" => 1}]
    end

    test "an unknown escort mob degrades rather than crashing" do
      entry = entry(%{"escorts" => [%{"mob" => "nope", "amount" => []}]})
      %{"escorts" => [escort]} = TarkovApi.boss_to_graphql(entry, @mobs, @locale)

      assert escort["boss"]["id"] == "nope"
      assert escort["boss"]["name"] == nil
    end
  end

  describe "the boss itself" do
    test "is re-inflated from the mob index and translated" do
      %{"boss" => boss} = TarkovApi.boss_to_graphql(entry(), @mobs, @locale)

      assert boss["id"] == "bossKojaniy"
      assert boss["name"] == "Shturman"
      assert boss["normalizedName"] == "shturman"
      assert boss["imagePortraitLink"] == "https://example.test/shturman.png"
    end

    # The maps sync degrades to an empty locale rather than failing outright, so
    # this path has to produce usable (if raw) output.
    test "an empty locale falls back to the raw values" do
      %{"boss" => boss} = TarkovApi.boss_to_graphql(entry(), @mobs, %{})
      assert boss["name"] == "Mob/Shturman"
    end
  end
end
