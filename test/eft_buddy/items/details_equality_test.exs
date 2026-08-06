defmodule EftBuddy.Items.DetailsEqualityTest do
  @moduledoc """
  The bulk detail build and the per-item read must return the same thing.

  This is the one test that matters for that change, because the failure mode is
  a panel that renders perfectly and is wrong — no crash, no error, no slow
  page. `EftBuddy.Items.Dataset` shipped with the same kind of test for the same
  reason, and its lesson is applied here structurally as well: the two paths are
  the SAME queries with the subject filter left off, so there is one query text
  rather than two implementations to keep in step. What remains testable, and is
  tested below, is that restricting a globally-ordered result to one item
  reproduces the per-item result exactly — order included.

  The fixture sweep is exhaustive rather than sampled: every seeded item, both
  game modes, full deep comparison. That is affordable here and it is the shape
  a hosted sample would only approximate.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Cache
  alias EftBuddy.Fixtures
  alias EftBuddy.Items

  setup do
    original_cache = Application.get_env(:eft_buddy, :cache_enabled)
    original_precompute = Application.get_env(:eft_buddy, :item_details_precompute_enabled)

    Application.put_env(:eft_buddy, :cache_enabled, true)
    Application.put_env(:eft_buddy, :item_details_precompute_enabled, true)
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      # `|| false`, not the raw original: restoring a previously-ABSENT key
      # writes `nil`, and `Application.get_env/3`'s default only applies to a
      # missing key — so the next reader gets nil rather than false, and a nil
      # chained through `and` raises.
      Application.put_env(:eft_buddy, :cache_enabled, original_cache || false)

      Application.put_env(
        :eft_buddy,
        :item_details_precompute_enabled,
        original_precompute || false
      )
    end)

    :ok
  end

  # A deliberately pathological catalogue: every section populated for some
  # item, and every edge case from the plan represented.
  defp seed do
    trader = Fixtures.trader(%{name: "Prapor", normalized_name: "prapor"})
    station = Fixtures.station(%{name: "Workbench", normalized_name: "workbench"})
    level = Fixtures.station_level(%{station_id: station.id, level: 2})

    bolts = Fixtures.item(%{name: "Bolts", normalized_name: "bolts"})
    wires = Fixtures.item(%{name: "Wires", normalized_name: "wires"})
    gunpowder = Fixtures.item(%{name: "Gunpowder", normalized_name: "gunpowder"})
    key_item = Fixtures.item(%{name: "Dorm Key", normalized_name: "dorm-key"})
    quest_item = Fixtures.item(%{name: "Golden Zibbo", normalized_name: "golden-zibbo"})
    orphan = Fixtures.item(%{name: "Orphan", normalized_name: "orphan"})

    # Hideout consumes bolts.
    Fixtures.item_requirement(%{level_id: level.id, item_id: bolts.id, quantity: 4})

    # A barter: wires + bolts -> gunpowder. Puts bolts in BOTH a barter and a
    # craft, and gives `required` a multi-row list whose order matters.
    for mode <- ["regular", "pve"] do
      barter =
        Fixtures.barter(%{trader_id: trader.id, level: 2, game_mode: mode, buy_limit: 3})

      Fixtures.barter_required(%{barter_id: barter.id, item_id: wires.id, count: 2})
      Fixtures.barter_required(%{barter_id: barter.id, item_id: bolts.id, count: 1})
      Fixtures.barter_reward(%{barter_id: barter.id, item_id: gunpowder.id, count: 1})
    end

    # A craft: bolts -> wires. Crafts carry no game_mode.
    craft = Fixtures.craft(%{station_level_id: level.id, duration: 120})
    Fixtures.craft_required(%{craft_id: craft.id, item_id: bolts.id, count: 5})
    Fixtures.craft_reward(%{craft_id: craft.id, item_id: wires.id, count: 1})

    # A multi-reward craft, to pin "primary output only".
    craft2 = Fixtures.craft(%{station_level_id: level.id, duration: 60})
    Fixtures.craft_required(%{craft_id: craft2.id, item_id: gunpowder.id, count: 1})
    Fixtures.craft_reward(%{craft_id: craft2.id, item_id: bolts.id, count: 2})
    Fixtures.craft_reward(%{craft_id: craft2.id, item_id: wires.id, count: 1})

    for mode <- ["regular", "pve"] do
      # Two tasks with the SAME NAME, to exercise the sort tie.
      task_a =
        Fixtures.task(%{
          name: "Debut",
          normalized_name: "debut-#{mode}",
          trader_id: trader.id,
          game_mode: mode
        })

      task_b =
        Fixtures.task(%{
          name: "Debut",
          normalized_name: "debut-two-#{mode}",
          trader_id: trader.id,
          game_mode: mode
        })

      # `payload.items`, with the SAME ITEM LISTED TWICE in one objective — the
      # count must not inflate.
      Fixtures.objective(%{
        task_id: task_a.id,
        payload: %{"items" => [bolts.id, bolts.id], "count" => 3, "foundInRaid" => true}
      })

      # Split across two objectives for the same item — MAX(count) wins.
      Fixtures.objective(%{
        task_id: task_a.id,
        payload: %{"items" => [bolts.id], "count" => 5, "foundInRaid" => true}
      })

      # A key reference. The item is a key, so EVERY reference to it reads as
      # one — including via `payload.items` on the other task.
      Fixtures.objective(%{
        task_id: task_b.id,
        payload: %{"required_key_ids" => [key_item.id]}
      })

      Fixtures.objective(%{
        task_id: task_a.id,
        payload: %{"items" => [key_item.id], "count" => 1}
      })

      # A quest item, referenced by the scalar key rather than the array.
      Fixtures.objective(%{
        task_id: task_b.id,
        payload: %{"questItem" => quest_item.id, "count" => 2}
      })

      # Payload shapes that a LATERAL-based expansion would raise on: an OBJECT
      # where an array is expected, and a missing key entirely.
      Fixtures.objective(%{task_id: task_a.id, payload: %{"items" => %{"not" => "an array"}}})
      Fixtures.objective(%{task_id: task_b.id, payload: %{"description" => "no item refs"}})

      # An id in the payload matching no item row — must produce no phantom.
      Fixtures.objective(%{
        task_id: task_a.id,
        payload: %{"items" => [Ecto.UUID.generate()]}
      })

      Fixtures.item_reward(%{task_id: task_a.id, item_id: gunpowder.id, quantity: 2})

      Fixtures.offer_unlock(%{
        task_id: task_b.id,
        item_id: wires.id,
        trader_id: trader.id,
        level: 3
      })
    end

    # No explicit price rows: `Fixtures.item/1` already inserts a `regular` one
    # and never a `pve` one, so every item here is present in one mode's prices
    # and absent from the other — the edge case this needed, for free.

    %{
      bolts: bolts,
      wires: wires,
      gunpowder: gunpowder,
      key_item: key_item,
      quest_item: quest_item,
      orphan: orphan
    }
  end

  defp all_seeded_ids(items), do: items |> Map.values() |> Enum.map(& &1.id)

  describe "the bulk build equals the lazy read" do
    test "for every seeded item, in both game modes" do
      items = seed()

      for mode <- [:pvp, :pve], item_id <- all_seeded_ids(items) do
        # Lazy: cache empty, so this computes through the per-item path.
        Cache.clear()
        lazy = Items.get_item_details(item_id, mode)

        # Bulk: build the whole catalogue, then read the same key.
        Cache.clear()
        assert {:ok, n} = Items.warm_item_details(mode)
        assert n > 0
        warm = Items.get_item_details(item_id, mode)

        assert warm == lazy, """
        #{inspect(mode)} / item #{item_id}: the bulk build and the lazy read disagree.

        This is the failure the whole subject-parameterisation exists to make
        impossible, and it renders as a perfectly normal-looking wrong panel.

        lazy: #{inspect(lazy, pretty: true, limit: :infinity)}

        warm: #{inspect(warm, pretty: true, limit: :infinity)}
        """
      end
    end

    test "an item with no relations at all gets every key, empty rather than absent" do
      # The likeliest bug in the change: an item absent from all eight grouped
      # maps must still get a full skeleton. A missing key crashes the template
      # rather than rendering an empty section.
      %{orphan: orphan} = seed()

      Cache.clear()
      assert {:ok, _} = Items.warm_item_details(:pvp)
      details = Items.get_item_details(orphan.id, :pvp)

      for key <- [
            :needed_by_tasks,
            :needed_by_hideout,
            :needed_for_crafts,
            :needed_for_barters,
            :obtained_from_tasks,
            :obtained_from_barters,
            :obtained_from_crafts,
            :unlocked_from_tasks
          ] do
        assert Map.fetch!(details, key) == [], "#{key} was not an empty list"
      end

      assert details.item.id == orphan.id
    end

    test "every item in the catalogue gets an entry, relations or not" do
      # Measured on the real catalogue before this was fixed: 1,772 of 5,449
      # items precomputed per mode. The section queries only return ids that
      # appear in some section, so the two thirds of the catalogue that are
      # loot, mods and ammo — with no task, hideout, barter or craft
      # involvement — got no entry and stayed exactly as slow as before.
      #
      # Which is most of what a visitor clicks, so the feature looked like it
      # was working while missing the common case.
      items = seed()
      Cache.clear()

      assert {:ok, n} = Items.warm_item_details(:pvp)
      assert n == Repo.aggregate(EftBuddy.Items.Item, :count)

      # The orphan has no relations whatsoever and must still be a cache hit.
      before = Cache.stats()
      assert Items.get_item_details(items.orphan.id, :pvp)

      assert Cache.stats().misses == before.misses,
             "an item with no relations was not precomputed"
    end

    test "a nonexistent item is nil and caches nothing" do
      seed()

      before = Cache.size()
      assert Items.get_item_details(Ecto.UUID.generate(), :pvp) == nil

      assert Cache.size() == before,
             "a nonexistent id minted a cache entry — 20,000 random UUIDs would fill the table"
    end
  end

  describe "the inverted quest queries" do
    test "a duplicate id inside one objective does not inflate the count" do
      %{bolts: bolts} = seed()

      Cache.clear()
      details = Items.get_item_details(bolts.id, :pvp)
      row = Enum.find(details.needed_by_tasks, &(&1.task_name == "Debut"))

      # MAX across the two objectives (3 and 5), not a sum, and not doubled by
      # the id appearing twice in one array.
      assert row.count == 5
    end

    test "an item used as a key anywhere reads as a key everywhere" do
      %{key_item: key_item} = seed()

      Cache.clear()
      details = Items.get_item_details(key_item.id, :pvp)

      refute details.needed_by_tasks == []
      assert Enum.all?(details.needed_by_tasks, &(&1.kind == :key))
    end

    test "a quest item referenced by the scalar key is surfaced" do
      %{quest_item: quest_item} = seed()

      Cache.clear()
      details = Items.get_item_details(quest_item.id, :pvp)

      assert [%{kind: :item, count: 2}] = details.needed_by_tasks
    end

    test "a non-array payload does not raise" do
      # The guard test. A LATERAL-based expansion evaluates the set-returning
      # function BEFORE the WHERE clause and raises "cannot extract elements
      # from an object" here — and passes every other test in this file.
      %{bolts: bolts} = seed()

      Cache.clear()
      assert Items.get_item_details(bolts.id, :pvp)
      assert {:ok, _} = Items.warm_item_details(:pvp)
    end

    test "an id matching no item row produces no phantom entry" do
      items = seed()

      Cache.clear()
      assert {:ok, n} = Items.warm_item_details(:pvp)

      # The bulk build groups by whatever id the payload carried, so a dangling
      # reference would mint a detail entry for an item that does not exist.
      assert n <= length(all_seeded_ids(items))
    end
  end

  describe "the price split" do
    test "the relational entry does not name PricesSync" do
      # The whole point of the split. With PricesSync in these sources, the
      # ten-minute price tick would throw away thousands of panels that do not
      # depend on prices — six times an hour.
      refute "PricesSync" in Items.detail_sources()

      for source <- ["ItemsSync", "TasksSync", "HideoutSync", "BartersSync", "CraftsSync"] do
        assert source in Items.detail_sources()
      end
    end

    test "a price sync leaves the relational entries standing" do
      %{bolts: bolts} = seed()

      Cache.clear()
      Items.get_item_details(bolts.id, :pvp)
      assert Cache.live?(Items.detail_key(bolts.id, "regular"))

      Cache.invalidate_source("PricesSync")
      assert Cache.live?(Items.detail_key(bolts.id, "regular"))

      Cache.invalidate_source("ItemsSync")
      refute Cache.live?(Items.detail_key(bolts.id, "regular"))
    end
  end

  describe "the memory budget" do
    test "a build that overruns unwinds itself rather than leaving a partial set" do
      # There is no automatic brake otherwise: the box this runs on has ~1.2GB
      # free, `restart: unless-stopped` brings the container back with the flag
      # still set, so an OOM mid-build is a crashloop rather than a one-off.
      #
      # Dropping the partial set costs nothing but latency — every missing key
      # falls through to the lazy path — and returning `{:skip, _}` rather than
      # `{:ok, 0}` is what withholds the coverage sentinel, so the set is reported
      # cold instead of claimed warm.
      #
      # That return value is the whole contract, and this test cannot see the half
      # that matters: the sentinel is written one layer up, by
      # `Cache.Warmer.record_outcome/4`. `EftBuddy.Cache.WarmerTest` covers it.
      seed()
      original = Application.get_env(:eft_buddy, :item_details_max_bytes)
      Application.put_env(:eft_buddy, :item_details_max_bytes, 1)
      on_exit(fn -> Application.put_env(:eft_buddy, :item_details_max_bytes, original) end)

      Cache.clear()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:skip, :over_budget} = Items.warm_item_details(:pvp)
        end)

      assert log =~ "exceeded its memory budget"
      assert log =~ "ITEM_DETAILS_MAX_MB"

      refute Enum.any?(
               Cache.entries(),
               &match?({EftBuddy.Items, :item_details_rel, _, _}, &1.key)
             )
    end

    test "the env var the over-budget message names is one runtime.exs actually reads" do
      # The message above told an operator to set ITEM_DETAILS_MAX_MB. Nothing in
      # the app read it — the string appeared exactly once in the repo, inside that
      # message — so following the instruction changed nothing and the next build
      # hit the same ceiling.
      #
      # Grepping config from a test is blunt, but `runtime.exs` is only evaluated
      # for :prod and cannot be exercised here, and the alternative is shipping
      # another instruction nobody can act on. `cleanup_guard_wiring_test.exs`
      # reads source files for the same reason.
      assert File.read!("config/runtime.exs") =~ "ITEM_DETAILS_MAX_MB",
             "the over-budget log names this env var; runtime.exs must read it"
    end

    test "warm-written entries and the coverage sentinel expire together" do
      # The constant-equality test in `warmer_test.exs` can pass while `put_many/3`
      # still passes a different `ttl_ms:`, so this pins what was actually WRITTEN.
      # That is the half that broke: the entries carried a hardcoded 8h while the
      # sentinel took the derived per-source value, and a sentinel outliving its
      # set is precisely what makes `skip?/1` refuse to rebuild something that is
      # already gone.
      seed()
      Cache.clear()

      # Stand in for a warm task: the warmer marks the process and installs the
      # per-spec TTL override before calling the builder, and the bulk write now
      # inherits it rather than passing a constant.
      ttl = EftBuddy.Cache.Warmer.warm_ttl_ms(Items.detail_sources())
      Cache.mark_warm_process()
      Cache.put_ttl_override(ttl)

      assert {:ok, n} = Items.warm_item_details(:pvp)
      assert n > 0

      sentinel_key = EftBuddy.Cache.Warmer.sentinel_key("items.details:pvp")
      Cache.put(sentinel_key, %{count: n}, Items.detail_sources())

      entries = Cache.entries()
      entry = Enum.find(entries, &match?({EftBuddy.Items, :item_details_rel, _, _}, &1.key))
      sentinel = Enum.find(entries, &(&1.key == sentinel_key))

      assert_in_delta entry.expires_in_ms, sentinel.expires_in_ms, 2_000
    end

    test "a lazily-read entry gets the same TTL as a warm-written one" do
      # The lazy path runs in a web process with no TTL override, so it has to pass
      # the derived value explicitly. Omitting it there would silently fall back to
      # the 20-minute default — the exact failure the original constant existed to
      # prevent, reintroduced by the fix for a different one.
      %{bolts: bolts} = seed()
      Cache.clear()

      Items.get_item_details(bolts.id, :pvp)

      entry =
        Cache.entries()
        |> Enum.find(&match?({EftBuddy.Items, :item_details_rel, _, _}, &1.key))

      assert_in_delta entry.expires_in_ms, Items.detail_ttl_ms(), 2_000
      refute_in_delta entry.expires_in_ms, Cache.default_ttl_ms(), 2_000
    end

    test "a build inside its budget writes normally" do
      seed()
      Cache.clear()

      assert {:ok, n} = Items.warm_item_details(:pvp)
      assert n > 0

      assert Enum.any?(
               Cache.entries(),
               &match?({EftBuddy.Items, :item_details_rel, _, _}, &1.key)
             )
    end
  end

  describe "cost" do
    test "the bulk build's query count does not scale with the catalogue" do
      # The property that makes precomputing thousands of panels possible at
      # all. Without this pinned, a refactor could reintroduce a per-item query
      # and every equality assertion above would still pass.
      seed()
      small = count_queries(fn -> Items.warm_item_details(:pvp) end)

      for n <- 1..40 do
        Fixtures.item(%{name: "Filler #{n}", normalized_name: "filler-#{n}"})
      end

      large = count_queries(fn -> Items.warm_item_details(:pvp) end)

      assert large == small, """
      The bulk build issued #{large} queries with 40 extra items but #{small} without.
      It must stay one pass per section regardless of catalogue size.
      """

      assert small > 0
    end
  end

  # No pid filter — see the note in `hideout_test.exs`.
  defp count_queries(fun) do
    test = self()
    handler = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:eft_buddy, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test, {handler, :query}) end,
      nil
    )

    try do
      fun.()
      drain(handler, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, acc) do
    receive do
      {^handler, :query} -> drain(handler, acc + 1)
    after
      0 -> acc
    end
  end
end
