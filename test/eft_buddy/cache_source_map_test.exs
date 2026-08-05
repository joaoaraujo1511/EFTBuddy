defmodule EftBuddy.CacheSourceMapTest do
  @moduledoc """
  Every cached read names the syncers whose completion should drop it. Getting
  that list wrong is the one caching mistake with no symptom: the page renders,
  the query is skipped, nothing errors, and the data is simply old — until the
  20-minute TTL papers over it and makes the pattern even harder to see.

  These tests pin the mapping that is easiest to get wrong, which is not the
  obvious owner but the **second** one — the syncer that writes a preloaded
  association rather than the primary table.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Cache
  alias EftBuddy.Fixtures

  setup do
    original = Application.get_env(:eft_buddy, :cache_enabled)
    Application.put_env(:eft_buddy, :cache_enabled, true)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      Application.put_env(:eft_buddy, :cache_enabled, original)
    end)

    :ok
  end

  # The cache is keyed on source NAMES, so a test that reaches into the ETS
  # table proves the wiring without needing each syncer to actually run.
  defp sources_for(key) do
    case Enum.find(Cache.entries(), &(&1.key == key)) do
      nil -> flunk("nothing cached under #{inspect(key)} — did the read stop caching?")
      entry -> entry.sources
    end
  end

  describe "reads whose preloads belong to a different syncer" do
    test "list_plates is dropped by ItemsSync, not just ArmorSync" do
      # `preload(:item)` pulls the name, icon and price that ItemsSync owns.
      # Keyed on ArmorSync alone, a renamed plate would keep its old name on the
      # page until the next armor sync — a day later.
      EftBuddy.Armor.list_plates()

      sources = sources_for({EftBuddy.Armor, :list_plates})

      assert "ArmorSync" in sources
      assert "ItemsSync" in sources
    end

    test "list_tasks is dropped by HideoutSync, not just TasksSync" do
      # The `:trader` preload resolves against `EftBuddy.Hideout.Trader`, which
      # the hideout sync writes — traders are not TasksSync's table.
      EftBuddy.Tasks.list_tasks(preloads: [:trader], game_mode: :pvp)

      sources = sources_for({EftBuddy.Tasks, :list_tasks, [:trader], :pvp})

      assert "TasksSync" in sources
      assert "HideoutSync" in sources
    end
  end

  describe "the ammo split" do
    test "ballistics and availability are separate entries with different owners" do
      EftBuddy.Ammo.list_rounds()

      ballistics = sources_for({EftBuddy.Ammo, :ballistics})
      availability = sources_for({EftBuddy.Ammo, :availability})

      # The whole point of the split: the ten-minute price tick must not be able
      # to throw away the expensive half.
      refute "PricesSync" in ballistics
      assert "PricesSync" in availability
    end

    test "a price refresh drops availability and leaves ballistics standing" do
      EftBuddy.Ammo.list_rounds()

      assert Cache.invalidate_source("PricesSync") == 1

      assert Enum.any?(Cache.entries(), &(&1.key == {EftBuddy.Ammo, :ballistics})),
             "the ten-minute price tick threw away the ballistics half"

      refute Enum.any?(Cache.entries(), &(&1.key == {EftBuddy.Ammo, :availability}))
    end

    test "a game patch drops both" do
      EftBuddy.Ammo.list_rounds()

      # ItemsSync owns both halves: it writes the item rows the rounds preload
      # AND cascades away the buy_for rows availability is derived from.
      assert Cache.invalidate_source("ItemsSync") == 2
    end

    test "list_rounds returns the same shape whether cached or not" do
      # The split changed how the result is assembled, so this pins that it did
      # not change WHAT is assembled.
      Application.put_env(:eft_buddy, :cache_enabled, false)
      uncached = EftBuddy.Ammo.list_rounds()

      Application.put_env(:eft_buddy, :cache_enabled, true)
      cached = EftBuddy.Ammo.list_rounds()

      assert uncached == cached
    end
  end

  describe "list_tasks caches only whitelisted option shapes" do
    test "the page's shape is cached" do
      EftBuddy.Tasks.list_tasks(preloads: [:trader], game_mode: :pvp)

      assert Cache.size() == 1
    end

    test "the storyline index shape is cached" do
      EftBuddy.Tasks.list_tasks(preloads: [])

      assert Cache.size() == 1
    end

    test "the DEFAULT preload set is deliberately NOT cached" do
      # Eleven associations and ~26MB per mode. Nothing calls it this way today;
      # the first caller that did would silently park that in ETS.
      EftBuddy.Tasks.list_tasks()

      assert Cache.size() == 0
    end

    test "an unrecognised option opts out rather than minting a new key" do
      # `list_tasks/1` is a general query builder. Keying on raw opts would key
      # the table on a space the function cannot bound — the same property that
      # disqualifies the flea-market reads entirely.
      EftBuddy.Tasks.list_tasks(preloads: [:trader], trader_slug: "prapor")
      EftBuddy.Tasks.list_tasks(preloads: [:trader], order_by: [desc: :name])

      assert Cache.size() == 0
    end

    test "different game modes do not collide" do
      EftBuddy.Tasks.list_tasks(preloads: [:trader], game_mode: :pvp)
      EftBuddy.Tasks.list_tasks(preloads: [:trader], game_mode: :pve)

      assert Cache.size() == 2
    end
  end

  describe "hideout requirements name ItemsSync" do
    test "level requirements are dropped by ItemsSync, not just HideoutSync" do
      # The value embeds `%Item{}` and the grid renders `item.name` and
      # `item.icon_link`. Keyed on HideoutSync alone — as it was — a renamed
      # item kept its old name on the grid until the next hideout sync, a DAILY
      # feed. This describe block is exactly the class of bug this module exists
      # for; hideout was simply never covered by it.
      station = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      level = Fixtures.station_level(%{station_id: station.id, level: 1})
      item = Fixtures.item(%{name: "Bolts", normalized_name: "bolts"})
      Fixtures.item_requirement(%{level_id: level.id, item_id: item.id, quantity: 1})

      EftBuddy.Hideout.get_level_requirements("medstation", 1)

      sources = sources_for({EftBuddy.Hideout, :level_requirements, "medstation", 1})

      assert "HideoutSync" in sources
      assert "ItemsSync" in sources
    end

    test "total item cost is dropped by ItemsSync too" do
      station = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      level = Fixtures.station_level(%{station_id: station.id, level: 1})
      item = Fixtures.item(%{name: "Bolts", normalized_name: "bolts"})
      Fixtures.item_requirement(%{level_id: level.id, item_id: item.id, quantity: 1})

      EftBuddy.Hideout.get_total_item_cost("medstation", 1)

      sources = sources_for({EftBuddy.Hideout, :total_item_cost, "medstation", 1})

      assert "HideoutSync" in sources
      assert "ItemsSync" in sources
    end
  end

  describe "key spaces stay bounded by rows that exist" do
    test "a batched hideout read mints nothing for a pair that does not exist" do
      # `fetch_many/4` stores only what the fill function returned. Without that
      # property the key space would be "whatever a caller asks about" rather
      # than "rows in hideout_station_levels".
      station = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      Fixtures.station_level(%{station_id: station.id, level: 1})

      EftBuddy.Hideout.get_level_requirements_for([
        {"medstation", 1},
        {"medstation", 99},
        {"no-such-station", 1}
      ])

      assert Cache.entries() |> Enum.map(& &1.key) == [
               {EftBuddy.Hideout, :level_requirements, "medstation", 1}
             ]
    end

    test "an unknown chapter slug caches nothing" do
      # The slug is a URL path param, so this key space was externally
      # controlled: every garbage slug was a round trip AND a cached nil, and a
      # few thousand of them would evict the whole table. `get_chapter/1` now
      # filters the already-warm chapter list instead of owning a key.
      assert EftBuddy.Chapters.get_chapter("../../etc/passwd") == nil

      refute Enum.any?(Cache.entries(), &match?({EftBuddy.Chapters, :chapter, _}, &1.key))
    end

    test "an unknown wiki slug caches nothing" do
      # `wiki_lookup_slugs/1` derives up to three candidate slugs per task from
      # its name, so caching every lookup would mint thousands of nil entries
      # keyed on strings no row will ever match.
      assert EftBuddy.Wiki.get_quest("no-such-quest") == nil

      refute Enum.any?(Cache.entries(), &match?({EftBuddy.Wiki, :quest, _}, &1.key))
    end
  end
end
