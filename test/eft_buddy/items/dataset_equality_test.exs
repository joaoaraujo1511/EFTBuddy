defmodule EftBuddy.Items.DatasetEqualityTest do
  @moduledoc """
  The dataset layer reimplements filtering, ordering and pagination in memory.
  Its failure mode is not a crash — it is **returning the wrong rows while
  looking completely healthy**: a search that quietly omits an item, a scope tab
  short by three, a page boundary off by one. None of that raises, none of it
  logs, and the page renders perfectly either way.

  So the contract is not "the dataset works", it is "the dataset is
  indistinguishable from SQL". These tests assert that directly, over a matrix
  of the option combinations the two pages actually produce, comparing row for
  row and in order.

  Ordering is the part most likely to diverge, and the reason it does not is
  that it is never computed here: Postgres produces the order once at build time
  and the dataset filters that list, which is stable. Against production,
  Postgres and `Enum.sort/1` disagree on the FIRST row of the default view —
  Postgres files `"Negotiation" room key` under N, byte order sorts it above
  `.300 Blackout AP` — so a version of this layer that sorted in Elixir would
  fail these tests immediately, which is exactly what should happen.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Fixtures
  alias EftBuddy.Items
  alias EftBuddy.Items.Dataset

  setup do
    original_cache = Application.get_env(:eft_buddy, :cache_enabled)
    original_dataset = Application.get_env(:eft_buddy, :item_dataset_enabled)

    # The dataset must be ON to be tested, and the read cache must be OFF: the
    # SQL side of every comparison has to actually hit the database, or these
    # would compare the dataset against itself.
    Application.put_env(:eft_buddy, :item_dataset_enabled, true)
    Application.put_env(:eft_buddy, :cache_enabled, false)
    Dataset.clear()

    on_exit(fn ->
      Dataset.clear()
      # `|| false` rather than the raw original: writing back a nil would leave
      # an explicitly-nil key, which `Application.get_env/3`'s default cannot
      # rescue, and every later test would inherit it.
      Application.put_env(:eft_buddy, :cache_enabled, original_cache || false)
      Application.put_env(:eft_buddy, :item_dataset_enabled, original_dataset || false)
    end)

    :ok
  end

  # A catalogue with the properties that actually break in-memory
  # reimplementations, rather than a tidy one.
  defp seed_catalogue do
    weapons = Fixtures.category(%{name: "Weapon", min_level_for_flea_market: 20})
    barter = Fixtures.category(%{name: "Barter item", min_level_for_flea_market: nil})

    # Leading punctuation — the collation trap. Postgres files these by their
    # first LETTER; byte order floats them above everything.
    mk("\"Negotiation\" room key", "negotiation-room-key", "Negotiation", barter, 5_000, nil)
    mk("#FireKlean gun lube", "firekleen-gun-lube", "FireKlean", barter, 12_000, nil)
    mk(".300 Blackout AP", "300-blackout-ap", "AP", weapons, 900, nil)

    # Mixed case, so a case-sensitive search or sort would show up.
    mk("Colt M4A1 5.56x45 assault rifle", "colt-m4a1", "M4A1", weapons, 40_000, 25)
    mk("colt lower receiver", "colt-lower-receiver", "Lower", weapons, 9_000, nil)

    # Search targets, including one that only matches on short_name.
    mk("Bolts", "bolts", "Bolt", barter, 1_200, nil)
    mk("Screw nuts", "screw-nuts", "Nuts", barter, 800, 0)

    # No flea price: must appear in the Items listing and must NOT appear
    # anywhere in the flea listing.
    mk("Unlisted prototype", "unlisted-prototype", "Proto", weapons, nil, nil)

    # Per-item level above the floor, and one at 0 — the case that rendered as
    # "buyable at level 1" before GREATEST/2 floored it.
    mk("Restricted optic", "restricted-optic", "Optic", weapons, 77_000, 40)
    mk("Cheap bolt", "cheap-bolt", "Cheap", barter, 300, 0)

    :ok
  end

  # `Fixtures.item/1` always writes a "regular" price row, so omitting
  # `last_low_price` produces an item that HAS a price row with a NULL price —
  # which is what a real unlisted item looks like, and is the case the flea
  # query's `not is_nil` guard exists for.
  defp mk(name, slug, short, category, flea_price, min_level) do
    attrs = %{
      name: name,
      normalized_name: slug,
      short_name: short,
      category_id: category.id,
      min_level_for_flea: min_level,
      base_price: 100
    }

    attrs = if flea_price, do: Map.put(attrs, :last_low_price, flea_price), else: attrs

    item = Fixtures.item(attrs)

    # A distinct PVE price, so a mode mix-up cannot pass silently.
    if flea_price do
      Fixtures.item_price(%{
        item_id: item.id,
        game_mode: "pve",
        base_price: 100,
        last_low_price: flea_price + 1
      })
    end

    item
  end

  defp build! do
    Dataset.refresh_catalog()
    Dataset.refresh_prices()
    assert Dataset.ready?(:pvp), "dataset did not become ready after a build"
  end

  # Compare by id AND position: `==` on the structs would also compare the
  # preloaded association structs, and the point here is the row set and its
  # order, which is what a visitor sees.
  defp ids(rows), do: Enum.map(rows, & &1.id)

  defp assert_same(opts, label) do
    sql = Items.list_all_items(opts)
    memory = Dataset.list_all_items(opts)

    assert ids(memory) == ids(sql), """
    #{label}
    opts:   #{inspect(opts)}
    sql:    #{inspect(Enum.map(sql, & &1.name))}
    memory: #{inspect(Enum.map(memory, & &1.name))}
    """
  end

  defp assert_same_flea(opts, label) do
    sql = Items.list_flea_market_items(opts)
    memory = Dataset.list_flea_market_items(opts)

    assert ids(memory) == ids(sql), """
    #{label}
    opts:   #{inspect(opts)}
    sql:    #{inspect(Enum.map(sql, & &1.name))}
    memory: #{inspect(Enum.map(memory, & &1.name))}
    """
  end

  describe "list_all_items — ordering" do
    setup do
      seed_catalogue()
      build!()
      :ok
    end

    test "every sort matches SQL, including the collation traps" do
      for sort <- [:default, :name_asc, :name_desc, :class_asc, :class_desc] do
        assert_same([sort: sort, limit: 100], "sort #{sort} diverged")
      end
    end

    test "the order follows the database's collation, not Elixir's byte order" do
      # THE LOCAL AND PRODUCTION DATABASES DO NOT SORT THE SAME WAY, and that is
      # the whole reason this layer never sorts. Measured: Supabase puts
      # ".300 Blackout AP" first, because its collation ignores leading
      # punctuation for primary weight. A stock local Postgres puts
      # "\"Negotiation\" room key" first, agreeing with byte order.
      #
      # So an implementation that sorted in Elixir would pass a local test suite
      # and be wrong in production — the same "invisible locally" trap that hid
      # the hideout N+1 for months. Asserting equality WITH THE DATABASE is the
      # only assertion that holds in both places.
      sql = Items.list_all_items(sort: :name_asc, limit: 100) |> Enum.map(& &1.name)
      memory = Dataset.list_all_items(sort: :name_asc, limit: 100) |> Enum.map(& &1.name)

      assert memory == sql

      # And where the database disagrees with byte order, prove this has teeth
      # rather than passing by coincidence. Vacuous on a byte-order collation,
      # load-bearing on production's.
      if sql != Enum.sort(sql) do
        refute memory == Enum.sort(sql),
               "the dataset reproduced byte order where the database did not"
      end
    end
  end

  describe "list_all_items — filtering" do
    setup do
      seed_catalogue()
      build!()
      :ok
    end

    test "search matches SQL for single tokens, multiple tokens and misses" do
      for q <- ["colt", "COLT", "bolt", "colt rifle", "assault 5.56", "zzzz", "", "   "] do
        assert_same([query: q, limit: 100], "search #{inspect(q)} diverged")
      end
    end

    test "search treats LIKE wildcards as literal characters" do
      # The SQL path escapes % and _ so a user typing them searches for them.
      # Substring matching has no wildcards, so this should be free — assert it
      # rather than assume it.
      for q <- ["%", "_", "100%", "a_b"] do
        assert_same([query: q, limit: 100], "wildcard #{inspect(q)} was treated as a wildcard")
      end
    end

    test "every scope tab matches SQL in both game modes" do
      for scope <- [:all, :hideout, :quest, :barter, :craft], mode <- [:pvp, :pve] do
        assert_same(
          [scope: scope, game_mode: mode, limit: 100],
          "scope #{scope}/#{mode} diverged"
        )
      end
    end

    test "category filtering matches SQL" do
      for names <- [[], ["Weapon"], ["Barter item"], ["Weapon", "Barter item"], ["Nonexistent"]] do
        assert_same([category_names: names, limit: 100], "categories #{inspect(names)} diverged")
      end
    end

    test "an unknown scope shows everything rather than nothing" do
      # Mirrors the SQL path's catch-all clause. The opposite behaviour — an
      # empty page — is the kind of thing that reads as "no results" rather than
      # as a bug.
      assert_same([scope: :not_a_real_scope, limit: 100], "unknown scope diverged")
    end
  end

  describe "list_all_items — favourites and paging" do
    setup do
      seed_catalogue()
      build!()
      :ok
    end

    test "favourites float to the top in the same order SQL puts them" do
      favourites = ["colt-m4a1", "bolts"]

      for scope <- [:all, :watchlist] do
        assert_same(
          [scope: scope, favorite_slugs: favourites, limit: 100],
          "favourites-first for #{scope} diverged"
        )
      end
    end

    test "an empty watchlist matches SQL" do
      assert_same([scope: :watchlist, favorite_slugs: [], limit: 100], "empty watchlist diverged")
    end

    test "blank and non-binary slugs are ignored exactly as SQL ignores them" do
      assert_same(
        [scope: :all, favorite_slugs: ["", nil, "bolts"], limit: 100],
        "slug cleaning diverged"
      )
    end

    test "every page boundary matches SQL" do
      # Off-by-one at a page boundary is the single most likely arithmetic slip
      # in a hand-rolled paginator, and infinite scroll walks every one of them.
      for limit <- [1, 3, 4], offset <- [0, 1, 3, 4, 9, 50] do
        assert_same([limit: limit, offset: offset], "page limit=#{limit} offset=#{offset}")
      end
    end

    test "paging is consistent with favourites applied" do
      favourites = ["bolts", "screw-nuts"]

      for offset <- [0, 1, 2, 3] do
        assert_same(
          [favorite_slugs: favourites, limit: 2, offset: offset],
          "favourite paging at offset #{offset}"
        )
      end
    end
  end

  describe "list_flea_market_items" do
    setup do
      seed_catalogue()
      build!()
      :ok
    end

    test "the base listing matches SQL in both modes" do
      for mode <- [:pvp, :pve] do
        assert_same_flea([game_mode: mode, limit: 100], "flea listing #{mode} diverged")
      end
    end

    test "items with no flea price never appear" do
      names = Dataset.list_flea_market_items(limit: 100) |> Enum.map(& &1.name)

      refute "Unlisted prototype" in names
    end

    test "buyable and locked match SQL across the level boundary" do
      # 15 is the flea unlock floor; 25 and 40 are per-item levels in the
      # fixture, so these levels straddle every threshold that exists.
      for status <- [:all, :buyable, :locked], level <- [1, 14, 15, 20, 25, 39, 40, 79] do
        assert_same_flea(
          [flea_status: status, pmc_level: level, limit: 100],
          "flea #{status} at level #{level} diverged"
        )
      end
    end

    test "the watchlist view matches SQL" do
      for slugs <- [[], ["bolts"], ["bolts", "cheap-bolt"], ["nope"]] do
        assert_same_flea(
          [flea_status: :watchlist, favorite_slugs: slugs, limit: 100],
          "flea watchlist #{inspect(slugs)} diverged"
        )
      end
    end

    test "search and category filters compose with status the same way" do
      for q <- ["", "bolt"], names <- [[], ["Barter item"]], status <- [:all, :buyable] do
        assert_same_flea(
          [query: q, category_names: names, flea_status: status, pmc_level: 30, limit: 100],
          "flea composition diverged"
        )
      end
    end

    test "flea paging matches SQL" do
      for limit <- [1, 2, 5], offset <- [0, 1, 2, 8] do
        assert_same_flea([limit: limit, offset: offset], "flea page #{limit}/#{offset}")
      end
    end
  end

  describe "flea_market_status_counts" do
    setup do
      seed_catalogue()
      build!()
      :ok
    end

    test "counts match SQL across levels, searches and watchlists" do
      for level <- [1, 15, 25, 40], q <- ["", "bolt"], slugs <- [[], ["bolts"]] do
        opts = [pmc_level: level, query: q, favorite_slugs: slugs]

        assert Dataset.flea_market_status_counts(opts) ==
                 Items.flea_market_status_counts(opts),
               "counts diverged for #{inspect(opts)}"
      end
    end

    test "the badges agree with the tabs they label" do
      # The SQL path shares one base query between the listing and the counts so
      # a badge can never disagree with its tab. The dataset must share its base
      # the same way.
      opts = [pmc_level: 30, query: "bolt"]

      counts = Dataset.flea_market_status_counts(opts)
      listed = Dataset.list_flea_market_items(opts ++ [flea_status: :buyable, limit: 1000])

      assert counts.buyable == length(listed)
    end
  end

  describe "price overlay" do
    setup do
      seed_catalogue()
      build!()
      :ok
    end

    test "overlaid price fields match SQL field for field" do
      # The overlay reimplements a LEFT JOIN's NULL semantics by hand, which is
      # exactly the kind of thing that looks right and is subtly wrong: a missing
      # price row must NULL the price columns rather than leave the items table's
      # own values showing.
      sql = Items.list_all_items(sort: :name_asc, limit: 100)
      memory = Dataset.list_all_items(sort: :name_asc, limit: 100)

      for {s, m} <- Enum.zip(sql, memory) do
        for field <- [
              :base_price,
              :last_low_price,
              :avg_24h_price,
              :low_24h_price,
              :high_24h_price,
              :historical_prices
            ] do
          assert Map.get(m, field) == Map.get(s, field),
                 "#{s.name}: #{field} was #{inspect(Map.get(m, field))}, SQL says #{inspect(Map.get(s, field))}"
        end
      end
    end

    test "the two game modes carry different prices" do
      [pvp] = Dataset.list_flea_market_items(game_mode: :pvp, query: "Cheap bolt", limit: 1)
      [pve] = Dataset.list_flea_market_items(game_mode: :pve, query: "Cheap bolt", limit: 1)

      assert pve.last_low_price == pvp.last_low_price + 1
    end
  end

  describe "readiness gating" do
    test "is not ready before a build, so callers fall back to SQL" do
      refute Dataset.ready?(:pvp)
    end

    test "is not ready when switched off, whatever has been built" do
      seed_catalogue()
      build!()

      Application.put_env(:eft_buddy, :item_dataset_enabled, false)

      refute Dataset.ready?(:pvp)
    end

    test "a catalogue rebuild picks up newly synced items" do
      seed_catalogue()
      build!()

      before = length(Dataset.list_all_items(limit: 1000))

      Fixtures.item(%{name: "Freshly synced thing", short_name: "Fresh", base_price: 1})
      Dataset.refresh_catalog()

      assert length(Dataset.list_all_items(limit: 1000)) == before + 1
    end

    test "a price refresh does not disturb the catalogue" do
      # The entire justification for two layers: the ten-minute price tick must
      # not rebuild the expensive half.
      seed_catalogue()
      build!()

      before = Dataset.list_all_items(sort: :name_asc, limit: 1000) |> ids()
      Dataset.refresh_prices()

      assert Dataset.list_all_items(sort: :name_asc, limit: 1000) |> ids() == before
    end
  end
end
