defmodule EftBuddy.TarkovApiFixtureTest do
  @moduledoc """
  Drives `EftBuddy.TarkovApi` with trimmed copies of the live tarkov.dev
  documents (test/fixtures/tarkov/). The adapter is the boundary where upstream
  drift turns into silently wrong data, and before these tests it was covered
  only by hand-built maps.

  Expected values are read from the fixture documents rather than written in,
  so refreshing the fixtures from the live API does not need these edited.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.TarkovApi
  alias EftBuddy.TarkovFixtures

  setup do
    %{fixtures: TarkovFixtures.stub()}
  end

  defp locale(mode, doc), do: TarkovFixtures.doc(mode, doc)["data"]

  describe "tasks/1" do
    test "task skill rewards and objectives carry the translated skill name" do
      # Audit H9: these used to pass through as raw enum keys ("Sniper").
      for mode <- ["regular", "pve"] do
        en = locale(mode, "tasks_en")
        raw = TarkovFixtures.doc(mode, "tasks")["data"]["tasks"]
        {:ok, tasks} = TarkovApi.tasks(mode)

        raw_skills =
          for t <- Map.values(raw),
              phase <- ["startRewards", "finishRewards"],
              e <- (t[phase] || %{})["skillLevelReward"] || [],
              do: e["skill"]

        adapted =
          for t <- tasks,
              phase <- ["startRewards", "finishRewards"],
              e <- (t[phase] || %{})["skillLevelReward"] || [],
              do: e["name"]

        assert "Sniper" in raw_skills
        assert Enum.sort(adapted) == raw_skills |> Enum.map(&Map.fetch!(en, &1)) |> Enum.sort()
        assert "Bolt-action Rifles" in adapted
        refute "Sniper" in adapted

        objective_skills =
          for t <- tasks, o <- t["objectives"], o["skillLevel"], do: o["skillLevel"]["name"]

        assert objective_skills != []
        assert Enum.all?(objective_skills, &(&1 in Map.values(en)))
      end
    end

    test "objectives no longer carry the untranslated fields nothing read" do
      # Audit L7.
      {:ok, tasks} = TarkovApi.tasks("regular")

      for t <- tasks, o <- t["objectives"] do
        for key <- ~w(targetNames bodyParts exitName exitStatus shotType playerLevel),
            do: refute(Map.has_key?(o, key))
      end
    end
  end

  describe "crafts/1" do
    test "quest-item ingredients are part of the recipe" do
      # Audit H10: `requiredQuestItems` used to be dropped, so these crafts were
      # shown as complete without their quest item.
      raw = TarkovFixtures.doc("regular", "crafts")["data"]
      {:ok, crafts} = TarkovApi.crafts("regular")

      for c <- raw, c["requiredQuestItems"] not in [nil, []] do
        adapted = Enum.find(crafts, &(&1["id"] == c["id"]))
        ingredient_ids = Enum.map(adapted["requiredItems"], & &1["item"]["id"])

        for qi <- c["requiredQuestItems"] do
          assert qi["item"] in ingredient_ids
          row = Enum.find(adapted["requiredItems"], &(&1["item"]["id"] == qi["item"]))
          assert row["count"] == 1
        end

        assert length(adapted["requiredItems"]) ==
                 length(c["requiredItems"]) + length(c["requiredQuestItems"])
      end
    end
  end

  describe "items/1 flea rows follow the GraphQL resolver's rule" do
    test "an item typed noFlea gets no flea rows, even with a price" do
      raw = TarkovFixtures.doc("regular", "items")["data"]["items"]

      no_flea =
        Enum.find_value(raw, fn {id, it} ->
          ("noFlea" in (it["types"] || []) and is_integer(it["lastLowPrice"])) && id
        end)

      assert no_flea, "the fixture should carry a noFlea item that still has a price"

      {:ok, items} = TarkovApi.items("regular")
      item = Enum.find(items, &(&1["id"] == no_flea))

      refute Enum.any?(
               item["sellFor"] ++ item["buyFor"],
               &(&1["vendor"]["normalizedName"] == "flea-market")
             )
    end

    test "a listed item sells at lastLowPrice and buys at avg24hPrice" do
      raw = TarkovFixtures.doc("regular", "items")["data"]["items"]

      {id, it} =
        Enum.find(raw, fn {_id, it} ->
          "noFlea" not in (it["types"] || []) and is_integer(it["avg24hPrice"]) and
            it["avg24hPrice"] != it["lastLowPrice"]
        end)

      {:ok, items} = TarkovApi.items("regular")
      item = Enum.find(items, &(&1["id"] == id))
      flea = &Enum.find(&1, fn row -> row["vendor"]["normalizedName"] == "flea-market" end)

      assert flea.(item["sellFor"])["price"] == it["lastLowPrice"]
      assert flea.(item["buyFor"])["price"] == it["avg24hPrice"]
    end

    test "every item category belongs to a filter group, and every caliber is labelled" do
      # Audit L19/L20: unknown categories matched no filter at all, and unknown
      # calibers sorted below grenades with a raw label.
      for mode <- ["regular", "pve"] do
        {:ok, items} = TarkovApi.items(mode)

        for %{"category" => %{"name" => name}} <- items do
          assert EftBuddy.ItemCategories.group_id_for(%{name: name}) != "others" or
                   name in EftBuddy.ItemCategories.names_for("others"),
                 "category #{inspect(name)} is in no filter group"
        end

        {:ok, rounds} = TarkovApi.ammo(mode)
        assert rounds != []
        for r <- rounds, do: assert(EftBuddy.Ammo.Caliber.known?(r["caliber"]), r["caliber"])
      end
    end
  end

  describe "barters/1" do
    test "fractional ingredient counts come through unrounded" do
      raw = TarkovFixtures.doc("regular", "barters")["data"]
      {:ok, barters} = TarkovApi.barters("regular")

      fractional =
        for b <- raw, r <- b["requiredItems"], r["count"] != trunc(r["count"]), do: r["count"]

      assert fractional != []

      adapted = for b <- barters, r <- b["requiredItems"], do: r["count"]
      for c <- fractional, do: assert(c in adapted)
    end
  end

  describe "traders/1" do
    test "returns every upstream trader, not only those a station or task mentions" do
      # Audit L21.
      raw = TarkovFixtures.doc("regular", "traders")["data"]
      {:ok, traders} = TarkovApi.traders("regular")

      assert length(traders) == map_size(raw)
      assert Enum.all?(traders, &(is_binary(&1["name"]) and is_binary(&1["normalizedName"])))
    end
  end

  describe "with_run_cache/1" do
    test "fetches each document once per run", %{fixtures: fixtures} do
      # Audit M10: one full Items run downloaded the items document three times
      # and the traders documents five times.
      TarkovApi.with_run_cache(fn ->
        {:ok, _} = TarkovApi.items("regular")
        {:ok, _} = TarkovApi.flea_prices("regular")
        {:ok, _} = TarkovApi.flea_market("regular")
        {:ok, _} = TarkovApi.barters("regular")
      end)

      paths = fixtures.paths.()
      assert Enum.count(paths, &(&1 == "/regular/items")) == 1
      assert Enum.count(paths, &(&1 == "/regular/traders")) == 1
      assert paths == Enum.uniq(paths)
    end

    test "nothing outlives the run", %{fixtures: fixtures} do
      TarkovApi.with_run_cache(fn -> {:ok, _} = TarkovApi.flea_prices("regular") end)
      {:ok, _} = TarkovApi.flea_prices("regular")

      assert Enum.count(fixtures.paths.(), &(&1 == "/regular/items")) == 2
    end
  end
end
