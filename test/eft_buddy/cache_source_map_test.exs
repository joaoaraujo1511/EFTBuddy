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

  describe "reads that count or join across feeds (audit H7)" do
    test "the item tab badges are dropped by every feed whose rows they count" do
      # Keyed on ItemsSync alone, the warmer rebuilt them seconds after the items
      # step, before barters and crafts committed, and kept that for 26 hours.
      EftBuddy.Items.scope_counts(:pvp)

      sources = sources_for({EftBuddy.Items, :scope_counts, :pvp})

      for feed <- ~w(ItemsSync QuestItemsSync TasksSync HideoutSync BartersSync CraftsSync) do
        assert feed in sources, "#{feed} writes rows scope_counts counts"
      end
    end

    test "a barter sync drops the badges" do
      EftBuddy.Items.scope_counts(:pvp)

      assert Cache.invalidate_source("BartersSync") >= 1
      refute Enum.any?(Cache.entries(), &(&1.key == {EftBuddy.Items, :scope_counts, :pvp}))
    end

    test "traders_with_tasks is dropped by HideoutSync, which writes the traders" do
      EftBuddy.Tasks.traders_with_tasks()

      sources = sources_for({EftBuddy.Tasks, :traders_with_tasks, nil})

      assert "TasksSync" in sources
      assert "HideoutSync" in sources
    end

    test "the warmer rebuilds both on the same feeds the reads are dropped by" do
      # Otherwise a feed drops the entry and nothing re-warms it, or a warm runs
      # on a feed that never invalidated it.
      specs = Map.new(EftBuddy.Cache.Warmer.default_specs(), &{&1.label, &1.sources})

      assert specs["items.scope_counts:pvp"] == EftBuddy.Items.scope_count_sources()
      assert specs["items.scope_counts:pve"] == EftBuddy.Items.scope_count_sources()
      assert specs["tasks.traders_with_tasks"] == EftBuddy.Tasks.traders_with_tasks_sources()
    end
  end

  describe "the map detail read (audit L23)" do
    test "is cached, and dropped by both feeds whose rows it preloads" do
      Fixtures.game_map(%{name: "Customs", normalized_name: "customs"})

      assert %{name: "Customs"} = EftBuddy.Maps.get_map_by_slug("customs", :pvp)

      sources = sources_for({EftBuddy.Maps, :map_by_slug, "customs", "regular"})
      assert "MapsSync" in sources
      assert "ItemsSync" in sources

      assert Cache.invalidate_source("ItemsSync") >= 1

      refute Enum.any?(
               Cache.entries(),
               &(&1.key == {EftBuddy.Maps, :map_by_slug, "customs", "regular"})
             )
    end

    test "a slug that names no map is not cached" do
      # Caching by whatever slug a URL carries would let anyone fill the cache.
      assert EftBuddy.Maps.get_map_by_slug("no-such-map-#{System.unique_integer()}", :pvp) == nil

      refute Enum.any?(Cache.entries(), &match?({EftBuddy.Maps, :map_by_slug, _, _}, &1.key))
    end
  end

  describe "chapter lookups (audit L25)" do
    setup do
      content = %{
        "normalized_name" => "boreas",
        "chapter_name" => "Boreas",
        "wiki_title" => "Boreas",
        "sections" => [
          %{
            "slug" => "guide",
            "level" => 2,
            "index" => "1",
            "heading" => "Guide",
            "wikitext" => "{|\n! Item Name\n! Amount\n|-\n| [[Bottle of Vodka]]\n| 2\n|}",
            "files" => []
          }
        ]
      }

      %EftBuddy.Chapters.ChapterPage{}
      |> EftBuddy.Chapters.ChapterPage.changeset(%{
        normalized_name: "boreas",
        chapter_name: "Boreas",
        content: content
      })
      |> EftBuddy.Repo.insert!()

      :ok
    end

    test "a chapter is served from its own entry, not the whole list" do
      assert %{normalized_name: "boreas"} = EftBuddy.Chapters.get_chapter("boreas")
      assert sources_for({EftBuddy.Chapters, :chapter, "boreas"}) == ["ChaptersSync"]
    end

    test "a slug that names no chapter creates no entry" do
      # The path param must not become a cache key space.
      assert EftBuddy.Chapters.get_chapter("no-such-chapter") == nil
      refute Enum.any?(Cache.entries(), &match?({EftBuddy.Chapters, :chapter, _}, &1.key))
    end

    test "an item's chapters come from one small index" do
      assert [%{slug: "boreas", title: "Boreas"}] =
               EftBuddy.Chapters.chapters_for_item(%{name: "Bottle of Vodka"})

      assert EftBuddy.Chapters.chapters_for_item(%{name: "Nothing Here"}) == []
      assert sources_for({EftBuddy.Chapters, :item_chapters}) == ["ChaptersSync"]
    end
  end

  describe "the ammo rounds" do
    test "are owned by the ammo and item feeds, not the ten-minute price tick" do
      EftBuddy.Ammo.list_rounds()

      assert sources_for({EftBuddy.Ammo, :list_rounds}) == ["AmmoSync", "ItemsSync"]
      assert Cache.invalidate_source("PricesSync") == 0
      assert Cache.invalidate_source("ItemsSync") == 1
    end

    test "list_rounds returns the same shape whether cached or not" do
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

    test "an unlisted preload shape opts out rather than minting a new key" do
      # Keying on the raw preload list would key the table on a space the
      # function cannot bound — the same property that disqualifies the
      # flea-market reads entirely.
      EftBuddy.Tasks.list_tasks(preloads: [:trader, :objectives], game_mode: :pvp)

      assert Cache.size() == 0
    end

    test "an unknown option raises instead of being silently ignored" do
      assert_raise ArgumentError, fn -> EftBuddy.Tasks.list_tasks(faction: :usec) end
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
