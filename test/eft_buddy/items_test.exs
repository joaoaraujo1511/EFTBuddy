defmodule EftBuddy.ItemsTest do
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Fixtures
  alias EftBuddy.Items

  defp names(rows), do: Enum.map(rows, & &1.name)

  describe "list_all_items/1 — search" do
    test "matches case-insensitively against name and short_name, AND-ing tokens" do
      Fixtures.item(%{name: "AK-74 Assault Rifle", short_name: "AK74"})
      Fixtures.item(%{name: "AK-12 Assault Rifle", short_name: "AK12"})
      Fixtures.item(%{name: "Bandage", short_name: "Band"})

      # Single token, case-insensitive.
      assert names(Items.list_all_items(query: "ak")) == [
               "AK-12 Assault Rifle",
               "AK-74 Assault Rifle"
             ]

      # AND-of-tokens: both "ak" and "74" must appear.
      assert names(Items.list_all_items(query: "ak 74")) == ["AK-74 Assault Rifle"]

      # Matches short_name too.
      assert names(Items.list_all_items(query: "band")) == ["Bandage"]
    end

    test "treats % and _ as literal characters, not wildcards" do
      pct = Fixtures.item(%{name: "50% discount voucher", short_name: "disc"})
      Fixtures.item(%{name: "AK-74", short_name: "ak74"})
      under = Fixtures.item(%{name: "a_b token", short_name: "ab"})
      Fixtures.item(%{name: "axb token", short_name: "axb"})

      assert names(Items.list_all_items(query: "50%")) == [pct.name]
      assert names(Items.list_all_items(query: "a_b")) == [under.name]
    end
  end

  describe "resolve_wiki_items/1" do
    test "matches real items by slug and exact name; drops non-items" do
      note = Fixtures.item(%{name: "Note for Kozlov", normalized_name: "note-for-kozlov"})

      issue =
        Fixtures.item(%{
          name: "The Ninth Circle Issue #14",
          normalized_name: "the-ninth-circle-issue-14"
        })

      result =
        Items.resolve_wiki_items([
          "Note for Kozlov",
          # wiki page title drops the "#"; resolves via the slug
          "The Ninth Circle Issue 14",
          # not a real item — must be absent
          "building materials"
        ])

      assert result["Note for Kozlov"].id == note.id
      assert result["The Ninth Circle Issue 14"].id == issue.id
      refute Map.has_key?(result, "building materials")
    end

    test "returns an empty map when nothing matches" do
      assert Items.resolve_wiki_items(["weapons", "armor"]) == %{}
    end
  end

  describe "list_all_items/1 — sort and pagination" do
    test "defaults to name ascending" do
      Fixtures.item(%{name: "Charlie"})
      Fixtures.item(%{name: "Alpha"})
      Fixtures.item(%{name: "Bravo"})

      assert names(Items.list_all_items()) == ["Alpha", "Bravo", "Charlie"]
    end

    test "sort: :price orders by last_low_price, falling back to base_price" do
      Fixtures.item(%{name: "NoFlea", base_price: 200, last_low_price: nil})
      Fixtures.item(%{name: "Cheap", base_price: 50, last_low_price: 500})
      Fixtures.item(%{name: "Tiny", base_price: 100, last_low_price: nil})

      assert names(Items.list_all_items(sort: :price)) == ["Cheap", "NoFlea", "Tiny"]
    end

    test "honors limit and offset" do
      for name <- ~w(Alpha Bravo Charlie Delta), do: Fixtures.item(%{name: name})

      assert names(Items.list_all_items(limit: 2, offset: 0)) == ["Alpha", "Bravo"]
      assert names(Items.list_all_items(limit: 2, offset: 2)) == ["Charlie", "Delta"]
    end
  end

  describe "list_all_items/1 — :hideout scope" do
    test "returns only items required by at least one hideout level" do
      station = Fixtures.station()
      level = Fixtures.station_level(%{station_id: station.id, level: 1})
      needed = Fixtures.item(%{name: "Bolts"})
      Fixtures.item(%{name: "Unrelated"})
      Fixtures.item_requirement(%{level_id: level.id, item_id: needed.id, quantity: 2})

      assert names(Items.list_all_items(scope: :hideout)) == ["Bolts"]
    end
  end

  describe "list_all_items/1 — :quest scope" do
    test "includes items referenced via payload items, required_key_ids, or questItem" do
      task = Fixtures.task(%{name: "Debut"})
      turn_in = Fixtures.item(%{name: "Turn In"})
      key = Fixtures.item(%{name: "Dorm Key"})
      quest_item = Fixtures.item(%{name: "Golden Zibbo", is_quest_item: true})
      Fixtures.item(%{name: "Unrelated"})

      Fixtures.objective(%{task_id: task.id, payload: %{"items" => [turn_in.id]}})
      Fixtures.objective(%{task_id: task.id, payload: %{"required_key_ids" => [key.id]}})
      Fixtures.objective(%{task_id: task.id, payload: %{"questItem" => quest_item.id}})

      assert names(Items.list_all_items(scope: :quest)) == ["Dorm Key", "Golden Zibbo", "Turn In"]
    end

    test "excludes items referenced only by a blacklisted task" do
      bad = Fixtures.task(%{name: "Circulate"})
      good = Fixtures.task(%{name: "Decontamination Service"})
      only_blacklisted = Fixtures.item(%{name: "Currency"})
      legit = Fixtures.item(%{name: "Legit"})

      Fixtures.objective(%{task_id: bad.id, payload: %{"items" => [only_blacklisted.id]}})
      Fixtures.objective(%{task_id: good.id, payload: %{"items" => [legit.id]}})

      assert names(Items.list_all_items(scope: :quest)) == ["Legit"]
    end
  end

  describe "list_all_items/1 — :barter scope" do
    test "includes items on either side of a barter and dedups contained ammo packs" do
      trader = Fixtures.trader()
      round = Fixtures.item(%{name: "Round"})
      box = Fixtures.item(%{name: "Pack of Round", contains_item_id: round.id})
      input = Fixtures.item(%{name: "Input Only"})
      Fixtures.item(%{name: "Unrelated"})

      barter = Fixtures.barter(%{trader_id: trader.id})
      # The API encodes the ammo barter at both the box and round ids.
      Fixtures.barter_reward(%{barter_id: barter.id, item_id: box.id})
      Fixtures.barter_reward(%{barter_id: barter.id, item_id: round.id})
      Fixtures.barter_required(%{barter_id: barter.id, item_id: input.id})

      # Round is hidden (its box covers it); box + input-only item remain.
      assert names(Items.list_all_items(scope: :barter)) == ["Input Only", "Pack of Round"]
    end
  end

  describe "list_flea_market_items/1" do
    test "returns only items with a flea price, ordered by price descending" do
      Fixtures.item(%{name: "Expensive", last_low_price: 9_000})
      Fixtures.item(%{name: "Cheap", last_low_price: 100})
      Fixtures.item(%{name: "NotOnFlea", last_low_price: nil})

      assert names(Items.list_flea_market_items()) == ["Expensive", "Cheap"]
    end

    test "filters by category name when given" do
      keys = Fixtures.category(%{name: "Keys"})
      meds = Fixtures.category(%{name: "Meds"})
      Fixtures.item(%{name: "Dorm Key", last_low_price: 5_000, category_id: keys.id})
      Fixtures.item(%{name: "Salewa", last_low_price: 3_000, category_id: meds.id})

      assert names(Items.list_flea_market_items(category_names: ["Keys"])) == ["Dorm Key"]
    end
  end

  describe "flea-market lock (effective level + status filter)" do
    alias EftBuddy.Items.{Category, Item}

    test "effective_flea_level/1 floors the per-item value at the global unlock level" do
      # minLevelForFlea below the floor (the tarkov.dev `0` case) clamps up.
      assert Items.effective_flea_level(%Item{min_level_for_flea: 0}) == 15
      # A higher per-item restriction is honored (e.g. Colt M4A1 = 25).
      assert Items.effective_flea_level(%Item{min_level_for_flea: 25}) == 25
      # NULL per-item value falls back to the category, then the global floor.
      assert Items.effective_flea_level(%Item{
               min_level_for_flea: nil,
               category: %Category{min_level_for_flea_market: 1}
             }) == 15

      assert Items.effective_flea_level(%Item{min_level_for_flea: nil, category: nil}) == 15
    end

    test "flea_locked?/2 gates on the effective level" do
      m4 = %Item{min_level_for_flea: 25}
      assert Items.flea_locked?(m4, 24)
      refute Items.flea_locked?(m4, 25)

      mod = %Item{min_level_for_flea: 0}
      # Locked below the global unlock floor even though the API says 0…
      assert Items.flea_locked?(mod, 14)
      # …and buyable once the operator hits the floor.
      refute Items.flea_locked?(mod, 15)
    end

    test "status counts treat the unlock level as a floor (the minLevelForFlea: 0 bug)" do
      cat = Fixtures.category(%{name: "Mods", min_level_for_flea_market: nil})
      # The exact tarkov.dev shape that used to leak through: tradeable but
      # reported as minLevelForFlea 0.
      Fixtures.item(%{
        name: "MOE grip",
        last_low_price: 4_200,
        min_level_for_flea: 0,
        category_id: cat.id
      })

      Fixtures.item(%{
        name: "Colt M4A1",
        last_low_price: 40_000,
        min_level_for_flea: 25,
        category_id: cat.id
      })

      # Below the flea unlock: nothing is buyable, everything is locked.
      assert %{all: 2, buyable: 0, locked: 2} =
               Items.flea_market_status_counts(pmc_level: 1)

      # At the unlock floor: the `0`-level mod becomes buyable; the M4 (25)
      # stays locked.
      assert %{all: 2, buyable: 1, locked: 1} =
               Items.flea_market_status_counts(pmc_level: 15)

      # At 25 both are buyable.
      assert %{all: 2, buyable: 2, locked: 0} =
               Items.flea_market_status_counts(pmc_level: 25)
    end

    test "list_flea_market_items honors :buyable/:locked with the floor" do
      cat = Fixtures.category(%{name: "Mods", min_level_for_flea_market: nil})

      Fixtures.item(%{
        name: "MOE grip",
        last_low_price: 4_200,
        min_level_for_flea: 0,
        category_id: cat.id
      })

      assert names(Items.list_flea_market_items(flea_status: :buyable, pmc_level: 14)) == []

      assert names(Items.list_flea_market_items(flea_status: :locked, pmc_level: 14)) == [
               "MOE grip"
             ]

      assert names(Items.list_flea_market_items(flea_status: :buyable, pmc_level: 15)) == [
               "MOE grip"
             ]
    end
  end

  describe "get_item_details/1" do
    test "returns nil for a missing or non-binary id" do
      assert Items.get_item_details(Ecto.UUID.generate()) == nil
      assert Items.get_item_details(nil) == nil
    end

    test "surfaces hideout, task-reward, and offer-unlock relationships" do
      item = Fixtures.item(%{name: "Salewa"})

      station = Fixtures.station(%{name: "Medstation"})
      level = Fixtures.station_level(%{station_id: station.id, level: 2})
      Fixtures.item_requirement(%{level_id: level.id, item_id: item.id, quantity: 5})

      reward_task = Fixtures.task(%{name: "Shortage"})

      Fixtures.item_reward(%{
        task_id: reward_task.id,
        item_id: item.id,
        quantity: 3,
        reward_phase: :finish
      })

      trader = Fixtures.trader(%{name: "Therapist"})
      unlock_task = Fixtures.task(%{name: "Healthcare Privacy"})

      Fixtures.offer_unlock(%{
        task_id: unlock_task.id,
        trader_id: trader.id,
        item_id: item.id,
        level: 2,
        reward_phase: :finish
      })

      details = Items.get_item_details(item.id)

      assert [%{station_name: "Medstation", level: 2, quantity: 5}] = details.needed_by_hideout
      assert [%{task_name: "Shortage", quantity: 3, phase: :finish}] = details.obtained_from_tasks

      assert [%{task_name: "Healthcare Privacy", trader_name: "Therapist", level: 2}] =
               details.unlocked_from_tasks
    end

    test "needed_by_tasks phrases plain item demands vs key items" do
      plain = Fixtures.item(%{name: "Bottle"})
      key = Fixtures.item(%{name: "Marked Key"})

      find_task = Fixtures.task(%{name: "Sanitary Standards"})

      Fixtures.objective(%{
        task_id: find_task.id,
        payload: %{"items" => [plain.id], "count" => 4, "foundInRaid" => true}
      })

      key_task = Fixtures.task(%{name: "The Key to Success"})
      Fixtures.objective(%{task_id: key_task.id, payload: %{"required_key_ids" => [key.id]}})

      assert [%{kind: :item, task_name: "Sanitary Standards", count: 4, found_in_raid: true}] =
               Items.get_item_details(plain.id).needed_by_tasks

      assert [%{kind: :key, task_name: "The Key to Success"}] =
               Items.get_item_details(key.id).needed_by_tasks
    end

    test "obtained_from_barters carries the output counts and the full required list" do
      trader = Fixtures.trader(%{name: "Prapor"})
      reward = Fixtures.item(%{name: "AK-74"})
      cost = Fixtures.item(%{name: "Wires"})

      barter = Fixtures.barter(%{trader_id: trader.id, level: 2})
      Fixtures.barter_reward(%{barter_id: barter.id, item_id: reward.id, count: 1, quantity: 1})
      Fixtures.barter_required(%{barter_id: barter.id, item_id: cost.id, count: 3, quantity: 3})

      assert [entry] = Items.get_item_details(reward.id).obtained_from_barters
      assert entry.trader_name == "Prapor"
      assert entry.level == 2
      assert [%{item: %{name: "Wires"}, count: 3, quantity: 3}] = entry.required
    end
  end

  describe "category_flags_for/2" do
    test "tags each item with every availability category it qualifies for" do
      # Needed for quests (turn-in target via payload items).
      task = Fixtures.task(%{name: "Debut"})
      quest_needed = Fixtures.item(%{name: "Turn In"})
      Fixtures.objective(%{task_id: task.id, payload: %{"items" => [quest_needed.id]}})

      # Obtained from quests (item reward).
      quest_reward = Fixtures.item(%{name: "Reward Gun"})
      Fixtures.item_reward(%{task_id: task.id, item_id: quest_reward.id})

      # Barter reward / input.
      trader = Fixtures.trader()
      barter = Fixtures.barter(%{trader_id: trader.id})
      barter_out = Fixtures.item(%{name: "Barter Out"})
      barter_in = Fixtures.item(%{name: "Barter In"})
      Fixtures.barter_reward(%{barter_id: barter.id, item_id: barter_out.id})
      Fixtures.barter_required(%{barter_id: barter.id, item_id: barter_in.id})

      # Craft reward / input.
      station = Fixtures.station()
      level = Fixtures.station_level(%{station_id: station.id, level: 1})
      craft = Fixtures.craft(%{station_level_id: level.id})
      craft_out = Fixtures.item(%{name: "Craft Out"})
      craft_in = Fixtures.item(%{name: "Craft In"})
      Fixtures.craft_reward(%{craft_id: craft.id, item_id: craft_out.id})
      Fixtures.craft_required(%{craft_id: craft.id, item_id: craft_in.id})

      # Hideout build cost.
      hideout = Fixtures.item(%{name: "Bolts"})
      Fixtures.item_requirement(%{level_id: level.id, item_id: hideout.id})

      plain = Fixtures.item(%{name: "Plain"})

      ids = [
        quest_needed.id,
        quest_reward.id,
        barter_out.id,
        barter_in.id,
        craft_out.id,
        craft_in.id,
        hideout.id,
        plain.id
      ]

      flags = Items.category_flags_for(ids, "regular")

      assert flags[quest_needed.id] == [:needed_for_quests]
      assert flags[quest_reward.id] == [:obtained_from_quests]
      assert flags[barter_out.id] == [:obtained_from_barters]
      assert flags[barter_in.id] == [:needed_for_barters]
      assert flags[craft_out.id] == [:obtained_from_crafts]
      assert flags[craft_in.id] == [:needed_for_crafts]
      assert flags[hideout.id] == [:needed_for_hideout]
      assert flags[plain.id] == []
    end

    test "surfaces quest keys and quest-exclusive items as needed_for_quests" do
      # This is the exact path (payload->'required_key_ids' / questItem via
      # the typed UUID union) that a raw string-id list must be able to
      # match — regression guard for the Postgrex uuid encode error.
      task = Fixtures.task(%{name: "Key Task"})
      key = Fixtures.item(%{name: "Dorm Key"})
      zibbo = Fixtures.item(%{name: "Golden Zibbo", is_quest_item: true})
      Fixtures.objective(%{task_id: task.id, payload: %{"required_key_ids" => [key.id]}})
      Fixtures.objective(%{task_id: task.id, payload: %{"questItem" => zibbo.id}})

      flags = Items.category_flags_for([key.id, zibbo.id], "regular")

      assert flags[key.id] == [:needed_for_quests]
      assert flags[zibbo.id] == [:needed_for_quests]
    end

    test "quest and barter tokens are game-mode scoped; hideout is not" do
      # Task / barter fixtures default to the regular (PVP) mode.
      task = Fixtures.task(%{name: "Regular Task"})
      quest_item = Fixtures.item(%{name: "Quest Target"})
      Fixtures.objective(%{task_id: task.id, payload: %{"items" => [quest_item.id]}})

      trader = Fixtures.trader()
      barter = Fixtures.barter(%{trader_id: trader.id})
      barter_item = Fixtures.item(%{name: "Barter Reward"})
      Fixtures.barter_reward(%{barter_id: barter.id, item_id: barter_item.id})

      station = Fixtures.station()
      level = Fixtures.station_level(%{station_id: station.id, level: 1})
      hideout_item = Fixtures.item(%{name: "Bolts"})
      Fixtures.item_requirement(%{level_id: level.id, item_id: hideout_item.id})

      ids = [quest_item.id, barter_item.id, hideout_item.id]

      regular = Items.category_flags_for(ids, "regular")
      assert regular[quest_item.id] == [:needed_for_quests]
      assert regular[barter_item.id] == [:obtained_from_barters]
      assert regular[hideout_item.id] == [:needed_for_hideout]

      # In PVE the regular-only quest/barter drop out (no more "marked but
      # empty"); the mode-agnostic hideout requirement stays.
      pve = Items.category_flags_for(ids, "pve")
      assert pve[quest_item.id] == []
      assert pve[barter_item.id] == []
      assert pve[hideout_item.id] == [:needed_for_hideout]
    end

    test "returns an empty map when given no ids" do
      assert Items.category_flags_for([]) == %{}
    end
  end

  describe "get_item_details/2 — barter game-mode isolation" do
    test "obtained_from_barters returns only the active mode's barter" do
      trader = Fixtures.trader()
      reward = Fixtures.item(%{name: "Reward"})
      reg_input = Fixtures.item(%{name: "Regular Input"})
      pve_input = Fixtures.item(%{name: "PVE Input"})

      reg_barter = Fixtures.barter(%{trader_id: trader.id, level: 1, game_mode: "regular"})
      Fixtures.barter_reward(%{barter_id: reg_barter.id, item_id: reward.id})
      Fixtures.barter_required(%{barter_id: reg_barter.id, item_id: reg_input.id})

      pve_barter = Fixtures.barter(%{trader_id: trader.id, level: 3, game_mode: "pve"})
      Fixtures.barter_reward(%{barter_id: pve_barter.id, item_id: reward.id})
      Fixtures.barter_required(%{barter_id: pve_barter.id, item_id: pve_input.id})

      assert [%{level: 1, required: [%{item: %{name: "Regular Input"}}]}] =
               Items.get_item_details(reward.id, :pvp).obtained_from_barters

      assert [%{level: 3, required: [%{item: %{name: "PVE Input"}}]}] =
               Items.get_item_details(reward.id, :pve).obtained_from_barters
    end
  end
end
