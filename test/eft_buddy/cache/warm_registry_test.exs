defmodule EftBuddy.Cache.WarmRegistryTest do
  @moduledoc """
  The warm registry declares, for each spec, which cache keys its MFA populates.
  That duplicates knowledge which already lives at the `Cache.fetch/4` call
  site, and it is the one new failure mode the declaration introduces — so it
  gets a test that runs every spec for real and compares.

  Two distinct bugs are in scope, and neither has a symptom:

    * **A wrong key.** The repair tick probes `:keys`, so a spec whose declared
      key is not the key its MFA writes is never skipped: it re-runs on every
      tick forever, issuing queries, while coverage reports it permanently cold.

    * **A wrong argument.** `EftBuddy.Items.scope_counts/1` and friends key on
      their raw argument, so warming with `"regular"` where the UI passes `:pvp`
      populates a key nothing reads. The warm appears to work, costs a query,
      and leaves the hit rate at zero. The warmer's own moduledoc warns about
      this; nothing tested it.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Cache
  alias EftBuddy.Cache.Warmer
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

  describe "every :entry spec declares exactly the keys it writes" do
    # Runs against an EMPTY database on purpose. A read that returns no rows
    # still caches its empty result, so the key appears either way — and an
    # empty catalogue keeps this fast and free of fixture coupling.
    for spec <- Warmer.default_specs(), spec.kind == :entry do
      @spec_under_test spec

      test "#{spec.label}" do
        spec = @spec_under_test
        {mod, fun, args} = spec.mfa

        Cache.clear()
        apply(mod, fun, args)

        written = Cache.entries() |> Enum.map(& &1.key) |> MapSet.new()
        declared = MapSet.new(spec.keys)

        refute Enum.empty?(spec.keys), "#{spec.label} declares no keys at all"

        assert MapSet.subset?(declared, written), """
        #{spec.label} declares keys it does not write.

        Declared but missing: #{inspect(MapSet.to_list(MapSet.difference(declared, written)))}
        Actually written:     #{inspect(MapSet.to_list(written))}

        The repair tick probes the declared keys, so a spec that never
        populates them is never skipped: it re-runs on every tick forever,
        issuing queries, while coverage reports it permanently cold. A declared
        key that differs from the written one — `"regular"` where the UI passes
        `:pvp`, say — looks exactly like this.
        """

        # The converse is NOT asserted. A spec's MFA may legitimately populate
        # other specs' keys on the way: `Wiki.quest_slugs/0` derives from
        # `all_quests/0`, and `Chapters.item_index/0` reads the chapter list and
        # the endings page. Those extra writes are shared work, not a mistake,
        # and each is probed by the spec that owns it.
      end
    end
  end

  describe "bulk builders write the keys their readers read" do
    test "tasks.details writes the key get_task_details/1 looks up" do
      trader = Fixtures.trader(%{name: "Prapor", normalized_name: "prapor"})

      task =
        Fixtures.task(%{name: "Debut", normalized_name: "debut", trader_id: trader.id})

      assert {:ok, 1} = EftBuddy.Tasks.warm_details()

      # Round-trip through the READER, not through the key expression, so a
      # builder writing a plausible-but-wrong key fails here.
      before = Cache.stats()
      assert %{id: id} = EftBuddy.Tasks.get_task_details(task.id)
      assert id == task.id

      assert Cache.stats().hits - before.hits == 1,
             "get_task_details/1 missed a key warm_details/0 had just written"
    end

    test "wiki.quests writes the key get_quest/1 looks up" do
      %EftBuddy.Wiki.QuestPage{}
      |> EftBuddy.Wiki.QuestPage.changeset(%{
        normalized_name: "debut",
        name: "Debut",
        wip: false,
        content: %{"task_name" => "Debut", "sections" => []}
      })
      |> Repo.insert!()

      assert {:ok, 1} = EftBuddy.Wiki.warm_quests()
      # The slug set is its own spec ("wiki.quest_slugs"), warmed alongside this
      # one in production. Warm it here too, so this measures the steady state
      # rather than a half-warmed node.
      EftBuddy.Wiki.quest_slugs()

      before = Cache.stats()
      assert EftBuddy.Wiki.get_quest("debut")

      # Two hits: the slug-set guard, then the quest itself. Both must be served
      # from memory — the guard missing would mean every quest lookup still pays
      # a round trip, which is most of what a cold expand costs.
      assert Cache.stats().hits - before.hits == 2
    end

    test "hideout.level_requirements writes the keys the grid reads" do
      station = Fixtures.station(%{name: "Medstation", normalized_name: "medstation"})
      Fixtures.station_level(%{station_id: station.id, level: 1})
      Fixtures.station_level(%{station_id: station.id, level: 2})

      assert {:ok, 2} = EftBuddy.Hideout.warm_level_requirements()

      before = Cache.stats()
      assert EftBuddy.Hideout.get_level_requirements("medstation", 1)

      assert Cache.stats().hits - before.hits == 1,
             "the grid's read missed a key warm_level_requirements/0 had written"
    end

    test "a bulk spec records a sentinel sharing its sources" do
      # The sentinel is how the repair tick knows a set is complete without
      # enumerating thousands of keys. Sharing the set's sources matters: a
      # sentinel that outlived its entries would suppress the very rebuild an
      # invalidation is supposed to trigger.
      Cache.put(Warmer.sentinel_key("tasks.details"), %{count: 3}, [
        "TasksSync",
        "ItemsSync",
        "HideoutSync",
        "MapsSync"
      ])

      assert Cache.live?(Warmer.sentinel_key("tasks.details"))

      Cache.invalidate_source("TasksSync")

      refute Cache.live?(Warmer.sentinel_key("tasks.details"))
    end
  end

  describe "bulk builders do not scale their query count with row count" do
    test "warming every task panel costs the same as warming a handful" do
      # The property that makes precomputing ~1,000 detail panels affordable:
      # `preload/2` batches PER ASSOCIATION across the whole result set, so
      # this is ~17 queries whatever the catalogue size. A future refactor that
      # reintroduces a per-task query would still pass every other test here.
      trader = Fixtures.trader(%{name: "Prapor", normalized_name: "prapor"})

      seed_tasks(1..3, trader)
      small = count_queries(fn -> EftBuddy.Tasks.warm_details() end)

      seed_tasks(4..40, trader)
      large = count_queries(fn -> EftBuddy.Tasks.warm_details() end)

      assert large == small, """
      Warming 40 task panels issued #{large} queries but 3 panels issued #{small}.
      `warm_details/0` must stay one preload pass over the whole table.
      """

      assert small > 0
    end
  end

  defp seed_tasks(range, trader) do
    for n <- range do
      Fixtures.task(%{
        name: "Quest #{n}",
        normalized_name: "quest-#{n}",
        trader_id: trader.id
      })
    end
  end

  # No pid filter: Ecto runs preloads in separate processes, and this whole
  # test is about the preloads.
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
