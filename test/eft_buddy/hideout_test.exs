defmodule EftBuddy.HideoutTest do
  # `async: false`: `count_queries/1` in the batching tests counts repo
  # telemetry with no pid filter (it has to — Ecto runs preloads in separate
  # processes), so a concurrently-running test's queries would be counted too.
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Fixtures
  alias EftBuddy.Hideout

  describe "list_modules/0" do
    test "returns one summary per station, name-sorted, with the max level" do
      med = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      Fixtures.station_level(%{station_id: med.id, level: 1})
      Fixtures.station_level(%{station_id: med.id, level: 2})
      Fixtures.station_level(%{station_id: med.id, level: 3})

      # A station with no levels should still appear with max: 0.
      Fixtures.station(%{name: "Stash", normalized_name: "stash"})

      assert [
               %{slug: "medstation", name: "Medstation", max: 3},
               %{slug: "stash", name: "Stash", max: 0}
             ] = Hideout.list_modules()
    end
  end

  describe "get_total_item_cost/2" do
    test "sums quantities per item across all levels up to the cap, roubles first" do
      station = Fixtures.station(%{name: "Generator", normalized_name: "generator"})
      l1 = Fixtures.station_level(%{station_id: station.id, level: 1})
      l2 = Fixtures.station_level(%{station_id: station.id, level: 2})
      l3 = Fixtures.station_level(%{station_id: station.id, level: 3})

      roubles = Fixtures.item(%{name: "Roubles", normalized_name: "roubles"})
      wires = Fixtures.item(%{name: "Wires", normalized_name: "wires"})

      Fixtures.item_requirement(%{level_id: l1.id, item_id: roubles.id, quantity: 50_000})
      Fixtures.item_requirement(%{level_id: l2.id, item_id: roubles.id, quantity: 150_000})
      Fixtures.item_requirement(%{level_id: l2.id, item_id: wires.id, quantity: 5})
      # Beyond the level-2 cap: must be excluded from the total.
      Fixtures.item_requirement(%{level_id: l3.id, item_id: wires.id, quantity: 99})

      assert [
               %{item: %{normalized_name: "roubles"}, quantity: 200_000},
               %{item: %{normalized_name: "wires"}, quantity: 5}
             ] = Hideout.get_total_item_cost("generator", 2)
    end

    test "returns [] for an unknown station or invalid level" do
      assert Hideout.get_total_item_cost("does-not-exist", 2) == []
      assert Hideout.get_total_item_cost("generator", 0) == []
    end
  end

  describe "get_level_requirements/2" do
    test "returns the four requirement lists, item requirements roubles-first" do
      station = Fixtures.station(%{name: "Lavatory", normalized_name: "lavatory"})
      level = Fixtures.station_level(%{station_id: station.id, level: 1})

      roubles = Fixtures.item(%{name: "Roubles", normalized_name: "roubles"})
      bolts = Fixtures.item(%{name: "Bolts", normalized_name: "bolts"})

      Fixtures.item_requirement(%{level_id: level.id, item_id: bolts.id, quantity: 3})
      Fixtures.item_requirement(%{level_id: level.id, item_id: roubles.id, quantity: 1_000})

      assert %{
               item_requirements: items,
               station_level_requirements: [],
               skill_requirements: [],
               trader_requirements: []
             } = Hideout.get_level_requirements("lavatory", 1)

      # Roubles sort ahead of everything, then alphabetical.
      assert Enum.map(items, & &1.item.normalized_name) == ["roubles", "bolts"]
    end

    test "returns nil for a missing station/level or invalid args" do
      Fixtures.station(%{name: "Lavatory", normalized_name: "lavatory"})

      assert Hideout.get_level_requirements("nope", 1) == nil
      assert Hideout.get_level_requirements("lavatory", 0) == nil
      assert Hideout.get_level_requirements("lavatory", "1") == nil
    end
  end

  describe "get_level_requirements_for/1" do
    # Builds `count` stations, each with a level 1 that needs one item. Every
    # name is suffixed with a unique integer so the helper can be called more
    # than once in a single test without tripping the unique indexes on
    # `hideout_stations.normalized_name` and `items.normalized_name`.
    defp stations_with_requirements(count) do
      uniq = System.unique_integer([:positive])
      item = Fixtures.item(%{name: "Roubles #{uniq}", normalized_name: "roubles-#{uniq}"})

      for n <- 1..count do
        slug = "station-#{uniq}-#{n}"
        station = Fixtures.station(%{name: "Station #{uniq}-#{n}", normalized_name: slug})
        level = Fixtures.station_level(%{station_id: station.id, level: 1})
        Fixtures.item_requirement(%{level_id: level.id, item_id: item.id, quantity: n * 100})
        slug
      end
    end

    # Counts EVERY repo query, with no pid filter.
    #
    # An earlier version filtered on `self() == test_pid`, reasoning that Ecto
    # emits its telemetry from the calling process. That is true of the parent
    # query and false of the preloads: Ecto runs those in SEPARATE processes, so
    # the filter counted 1 of the ~5 queries a preloaded read issues and the
    # "does not scale" assertion below was measuring almost nothing. Counting
    # everything is why this module is `async: false`.
    defp count_queries(fun) do
      counter = :counters.new(1, [])
      handler_id = {__MODULE__, System.unique_integer()}

      :telemetry.attach(
        handler_id,
        [:eft_buddy, :repo, :query],
        fn _event, _measure, _meta, _cfg -> :counters.add(counter, 1, 1) end,
        nil
      )

      try do
        result = fun.()
        {result, :counters.get(counter, 1)}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "returns the real requirement content, keyed by {slug, level}" do
      # Asserts on CONTENT rather than against `get_level_requirements/2`.
      # Comparing the two used to be meaningful when each issued its own query;
      # now that the single-pair function delegates to this one, such a
      # comparison would be tautological and would pass even if both returned
      # nonsense.
      station = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      level = Fixtures.station_level(%{station_id: station.id, level: 1})
      item = Fixtures.item(%{name: "Bolts", normalized_name: "bolts"})
      Fixtures.item_requirement(%{level_id: level.id, item_id: item.id, quantity: 7})

      batched = Hideout.get_level_requirements_for([{"medstation", 1}])

      assert %{item_requirements: [req]} = batched[{"medstation", 1}]
      assert req.quantity == 7
      assert req.item.name == "Bolts"
    end

    test "query count does NOT scale with the number of stations" do
      # The whole point. Per-station fetching cost one query for the level plus
      # one per preloaded association, so 26 stations meant 155 queries and, on a
      # database ~76ms away, 7.1 seconds. Batched, the preloads run once for the
      # entire set, so asking for eight stations costs the same as asking for one.
      one = stations_with_requirements(1)

      {_, queries_for_one} =
        count_queries(fn -> Hideout.get_level_requirements_for([{hd(one), 1}]) end)

      many = stations_with_requirements(8)
      pairs = Enum.map(many, &{&1, 1})

      {result, queries_for_many} =
        count_queries(fn -> Hideout.get_level_requirements_for(pairs) end)

      assert map_size(result) == 8

      assert queries_for_many == queries_for_one,
             """
             Expected a constant query count regardless of station count.
             1 station: #{queries_for_one} queries; 8 stations: #{queries_for_many}.
             A count that grows with the input means the N+1 is back.
             """
    end

    test "returns an empty map for no pairs, and issues no query at all" do
      {result, queries} = count_queries(fn -> Hideout.get_level_requirements_for([]) end)

      assert result == %{}
      assert queries == 0
    end

    test "silently omits pairs that do not exist" do
      [slug] = stations_with_requirements(1)

      result = Hideout.get_level_requirements_for([{slug, 1}, {slug, 99}, {"nope", 1}])

      assert Map.keys(result) == [{slug, 1}]
    end

    test "handles several distinct levels in one call" do
      station = Fixtures.station(%{name: "Generator", normalized_name: "generator"})
      other = Fixtures.station(%{name: "Lavatory", normalized_name: "lavatory"})
      Fixtures.station_level(%{station_id: station.id, level: 1})
      Fixtures.station_level(%{station_id: station.id, level: 2})
      Fixtures.station_level(%{station_id: other.id, level: 3})

      result =
        Hideout.get_level_requirements_for([
          {"generator", 2},
          {"lavatory", 3}
        ])

      # Exactly the requested pairs — the level-grouped WHERE must not widen into
      # the cartesian product of every slug against every level.
      assert Enum.sort(Map.keys(result)) == [{"generator", 2}, {"lavatory", 3}]
    end
  end
end
