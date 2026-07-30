defmodule EftBuddy.Items.SyncCleanupStaleTest do
  @moduledoc """
  Characterisation tests for `EftBuddy.Items.Sync.cleanup_stale/2` — the
  highest-blast-radius prune in the application.

  `items.id` is referenced with `on_delete: :delete_all` by
  `hideout_item_requirements`, `task_item_rewards` and `task_offer_unlocks`. None of
  those are rebuilt by the items sync: `Hideout.Sync` and `Tasks.Sync` run from the
  boot sequence, not from the periodic items tick. So a delete here does not merely
  remove an item — it silently empties hideout station requirements and task rewards,
  and the pages then render "this station needs no items" as fact.

  Two things stand between a truncated upstream response and that outcome, and this
  module pins both:

    1. `Sync.Helpers.cleanup_safe?/3` refusing an implausibly small snapshot. The
       guard itself is well tested; what was untested is whether the **call site
       honours it** — a `{:skip, _}` branch that logged and then deleted anyway would
       look identical in the guard's own tests.
    2. The `is_quest_item == false` scope. Quest items live in this same table but
       are synced from a separate upstream query, so their external ids are NEVER in
       the regular snapshot — without the scope, every items sync would delete every
       quest item, and re-inserting them afterwards with fresh UUIDs would dangle
       every objective payload `Tasks.Sync` had baked them into.
  """
  use EftBuddy.DataCase, async: false

  import EftBuddy.Fixtures

  alias EftBuddy.Items.Item
  alias EftBuddy.Items.Sync
  alias EftBuddy.Sync.Reporter

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  # A snapshot row as the upstream response carries it.
  defp snapshot(external_ids), do: Enum.map(external_ids, &%{"id" => &1})

  defp external_ids, do: Item |> select([i], i.external_id) |> Repo.all() |> Enum.sort()

  describe "the guard is honoured, not merely consulted" do
    test "a truncated snapshot deletes nothing" do
      # 20 items in the table, 1 in the snapshot: far below the 90% keep ratio.
      for n <- 1..20, do: item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})

      assert {:ok, counts} = Sync.cleanup_stale(Repo, snapshot(["item-1"]))

      assert counts.items == 0
      assert length(external_ids()) == 20
    end

    test "and the refusal is recorded against the run, so /health/sync can see it" do
      # A refused prune leaves the run reporting `outcome: :ok` — it did complete. The
      # refusal has to travel separately or the app's most destructive failure mode
      # announces itself as a healthy run.
      for n <- 1..20, do: item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})

      Reporter.attach_telemetry()

      Reporter.with_run("ItemsSync", fn ->
        Sync.cleanup_stale(Repo, snapshot(["item-1"]))
        :ok
      end)

      assert %{"ItemsSync" => %{outcome: :ok, refusals: refusals}} = Reporter.status()
      assert refusals >= 1
    end

    test "a healthy snapshot DOES prune, so the guard is not just always refusing" do
      # Without this the tests above would pass against a function that deletes
      # nothing ever.
      #
      # 10 rows keeping 9 sits EXACTLY on the 0.9 floor (`snapshot >= current *
      # ratio` is inclusive). That is deliberate - it pins the boundary from the
      # permissive side, where `cleanup_safe?/3`'s own tests pin it from the
      # refusing side. If the ratio is ever raised again this test fails, which is
      # the correct outcome: raising it past 0.9 means a single-row prune is no
      # longer possible on a 10-row table, and that is a decision worth noticing.
      for n <- 1..10, do: item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})

      kept = Enum.map(1..9, &"item-#{&1}")

      assert {:ok, counts} = Sync.cleanup_stale(Repo, snapshot(kept))

      assert counts.items == 1
      assert external_ids() == Enum.sort(kept)
    end

    test "an empty snapshot is refused outright" do
      # `valid_ids == []` short-circuits before the guard: upstream returning zero
      # items is a failure, not an instruction to empty the catalogue.
      for n <- 1..3, do: item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})

      assert {:ok, %{items: 0}} = Sync.cleanup_stale(Repo, [])
      assert length(external_ids()) == 3
    end
  end

  describe "the cascade the guard is actually protecting" do
    test "a refused prune leaves hideout requirements intact" do
      # THE POINT. Blocker 4's lesson was that a guard which refuses the parent prune
      # while the children are wiped anyway is worse than no guard. This asserts the
      # protective direction: refuse, and the dependent rows survive.
      station = station(%{normalized_name: "workbench"})
      level = station_level(%{station_id: station.id, level: 1})

      needed =
        for n <- 1..20 do
          i = item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})
          item_requirement(%{level_id: level.id, item_id: i.id})
          i
        end

      assert {:ok, %{items: 0}} = Sync.cleanup_stale(Repo, snapshot(["item-1"]))

      for i <- needed do
        assert Repo.get(Item, i.id), "item #{i.external_id} must survive a refused prune"
      end

      assert Repo.aggregate(EftBuddy.Hideout.ItemRequirement, :count, :id) == 20
    end

    test "an ALLOWED prune does cascade — which is why the guard matters" do
      # The other half of the contract, stated explicitly rather than left implicit:
      # when the guard permits the delete, dependent rows really do go, and nothing in
      # the items sync rebuilds them. This is the behaviour the recurring ordered sync
      # cycle exists to make survivable.
      station = station(%{normalized_name: "workbench"})
      level = station_level(%{station_id: station.id, level: 1})

      for n <- 1..10 do
        i = item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})
        item_requirement(%{level_id: level.id, item_id: i.id})
      end

      # 9 of 10 retained: comfortably above the keep ratio, so the prune proceeds.
      assert {:ok, %{items: 1}} =
               Sync.cleanup_stale(Repo, snapshot(Enum.map(1..9, &"item-#{&1}")))

      assert Repo.aggregate(EftBuddy.Hideout.ItemRequirement, :count, :id) == 9,
             "the deleted item's requirement row cascaded away, and nothing rebuilds it"
    end
  end

  describe "quest items are never collateral" do
    test "a regular items prune leaves quest items alone" do
      # Quest items share this table but come from a different upstream query, so
      # their external ids can never appear in `valid_ids`. Without the
      # `is_quest_item == false` scope every items sync would delete every quest item
      # — and `sync_quest_items` re-inserting them with fresh UUIDs would dangle every
      # objective payload `Tasks.Sync` had already resolved against the old ones.
      # That is a real bug this scope fixed; this is the test that keeps it fixed.
      for n <- 1..10, do: item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})

      quest =
        item(%{
          external_id: "quest-item-1",
          normalized_name: "quest-item-1",
          is_quest_item: true
        })

      assert {:ok, %{items: 1}} =
               Sync.cleanup_stale(Repo, snapshot(Enum.map(1..9, &"item-#{&1}")))

      assert Repo.get(Item, quest.id), "a quest item must never be pruned by the items sync"
    end

    test "quest items do not count toward the guard's denominator either" do
      # If they did, a table padded with quest items would make a healthy regular
      # snapshot look truncated and the guard would refuse every legitimate prune —
      # failing safe, but permanently, and silently.
      #
      # The counts are chosen to sit clear of the keep-ratio floor in BOTH
      # directions, so this test fails only for its own reason. What is under test
      # is which rows land in the denominator, not where the threshold is.
      for n <- 1..20, do: item(%{external_id: "item-#{n}", normalized_name: "item-#{n}"})

      for n <- 1..40 do
        item(%{
          external_id: "quest-item-#{n}",
          normalized_name: "quest-item-#{n}",
          is_quest_item: true
        })
      end

      # 19 of the 20 REGULAR items retained — 95%, comfortably above the floor.
      # Against all 60 rows it would read as 32% and the prune would be refused.
      assert {:ok, %{items: 1}} =
               Sync.cleanup_stale(Repo, snapshot(Enum.map(1..19, &"item-#{&1}")))
    end
  end
end
