defmodule EftBuddy.Hideout.SyncReplaceLevelChildrenTest do
  @moduledoc """
  Characterisation tests for `EftBuddy.Hideout.Sync.replace_level_children/5` —
  the second, previously untouched half of the destructive-delete defect that
  `EftBuddy.Items.SyncReplaceChildrenTest` covers for barters and crafts.

  It is the worse of the two. The function deletes from FOUR child tables
  (`item_requirements`, `station_level_requirements`, `skill_requirements`,
  `trader_requirements`), and its scope used to come from `fetch_level_map/2`,
  which reads the ENTIRE `station_levels` table. `cleanup_stale/2` then refuses to
  prune the stations a truncated snapshot omitted, so the result is hideout
  stations rendering with zero item, skill, trader and prerequisite requirements —
  presented to the user as fact.

  It also had no protective empty-rows clause, and `EftBuddy.Sync.Bootstrap` runs
  the hideout sync whether or not the items sync succeeded. With an empty items
  table every item requirement falls through the "item not found" skip, so `rows`
  arrives empty and every requirement row in the database was deleted with nothing
  reinserted.

  This module had **no tests at all** before these.
  """
  use EftBuddy.DataCase, async: true

  import EftBuddy.Fixtures

  alias EftBuddy.Hideout.ItemRequirement
  alias EftBuddy.Hideout.Sync

  defp requirement_item_ids(level_id) do
    ItemRequirement
    |> where(level_id: ^level_id)
    |> select([r], r.item_id)
    |> Repo.all()
  end

  # A station with two levels, each carrying one item requirement. The next
  # snapshot will carry level 1 and not level 2.
  defp station_with_two_levels do
    st = station(%{normalized_name: "workbench"})
    kept_item = item(%{name: "Kept requirement"})
    stale_item = item(%{name: "Stale requirement"})

    in_snapshot = station_level(%{station_id: st.id, level: 1})
    absent = station_level(%{station_id: st.id, level: 2})

    item_requirement(%{level_id: in_snapshot.id, item_id: kept_item.id})
    item_requirement(%{level_id: absent.id, item_id: stale_item.id})

    %{
      station: st,
      in_snapshot: in_snapshot,
      absent: absent,
      kept_item: kept_item,
      stale_item: stale_item
    }
  end

  # What `fetch_level_map/2` returns: every level in the table, keyed
  # `{station_slug, level}`. Handing this to the delete unscoped is the bug.
  defp whole_table_level_map(%{in_snapshot: in_snapshot, absent: absent}) do
    %{{"workbench", 1} => in_snapshot.id, {"workbench", 2} => absent.id}
  end

  # The upstream snapshot shape, carrying only the given level numbers.
  defp snapshot(levels) do
    [%{"normalizedName" => "workbench", "levels" => Enum.map(levels, &%{"level" => &1})}]
  end

  defp requirement_row(level_id, item_id, quantity) do
    %{id: Ecto.UUID.generate(), level_id: level_id, item_id: item_id, quantity: quantity}
  end

  test "replaces the requirements of levels in the snapshot" do
    levels = station_with_two_levels()
    %{in_snapshot: in_snapshot, stale_item: replacement} = levels

    Sync.replace_level_children(
      Repo,
      ItemRequirement,
      snapshot([1]),
      whole_table_level_map(levels),
      [requirement_row(in_snapshot.id, replacement.id, 4)]
    )

    assert requirement_item_ids(in_snapshot.id) == [replacement.id]
  end

  test "leaves the requirements of levels ABSENT from the snapshot untouched" do
    # THE REGRESSION. The level map necessarily carries both levels — it is read
    # back from the table — while this run's snapshot carries only level 1.
    levels = station_with_two_levels()

    %{in_snapshot: in_snapshot, absent: absent, kept_item: kept_item, stale_item: stale_item} =
      levels

    Sync.replace_level_children(
      Repo,
      ItemRequirement,
      snapshot([1]),
      whole_table_level_map(levels),
      [requirement_row(in_snapshot.id, kept_item.id, 1)]
    )

    assert requirement_item_ids(absent.id) == [stale_item.id],
           "requirements of a level the snapshot did not carry must survive"

    # Proves the delete ran at all rather than the whole call being a no-op.
    assert requirement_item_ids(in_snapshot.id) == [kept_item.id]
  end

  test "clears a snapshot level whose own requirements vanished" do
    # Rules out deriving the scope from `rows`: the function is called once for the
    # whole snapshot, so a level that legitimately lost all its requirements
    # contributes no rows and must still be cleared.
    levels = station_with_two_levels()
    %{in_snapshot: keeps, absent: loses, kept_item: kept_item} = levels

    Sync.replace_level_children(
      Repo,
      ItemRequirement,
      snapshot([1, 2]),
      whole_table_level_map(levels),
      [requirement_row(keeps.id, kept_item.id, 1)]
    )

    assert requirement_item_ids(keeps.id) == [kept_item.id]
    assert requirement_item_ids(loses.id) == []
  end

  test "an entirely empty requirement set is treated as untrustworthy and deletes nothing" do
    # This is the `Bootstrap` case, and it is not hypothetical: `Bootstrap` runs the
    # hideout sync regardless of whether the items sync succeeded, and with an empty
    # items table EVERY item requirement falls through the "not found in items" skip.
    # `rows == []` therefore means "we resolved nothing", not "there is nothing" —
    # so keep what is there. Deliberate; pinned so nobody removes the clause.
    levels = station_with_two_levels()
    %{in_snapshot: in_snapshot, absent: absent} = levels

    Sync.replace_level_children(
      Repo,
      ItemRequirement,
      snapshot([1, 2]),
      whole_table_level_map(levels),
      []
    )

    assert length(requirement_item_ids(in_snapshot.id)) == 1
    assert length(requirement_item_ids(absent.id)) == 1
  end

  test "a badly truncated snapshot cannot reach the rest of the table" do
    # The real failure shape: upstream answers 200 with a fraction of the stations.
    ingredient = item(%{name: "Ingredient"})

    levels =
      for n <- 1..12 do
        st = station(%{normalized_name: "station-#{n}"})
        lvl = station_level(%{station_id: st.id, level: 1})
        item_requirement(%{level_id: lvl.id, item_id: ingredient.id})
        {"station-#{n}", lvl}
      end

    level_map = Elixir.Map.new(levels, fn {slug, lvl} -> {{slug, 1}, lvl.id} end)
    [{_slug, first} | rest] = levels

    Sync.replace_level_children(
      Repo,
      ItemRequirement,
      [%{"normalizedName" => "station-1", "levels" => [%{"level" => 1}]}],
      level_map,
      [requirement_row(first.id, ingredient.id, 9)]
    )

    for {slug, lvl} <- rest do
      assert requirement_item_ids(lvl.id) == [ingredient.id],
             "a 1-of-12 snapshot must not authorise wiping #{slug}'s requirements"
    end
  end

  describe "snapshot_level_ids/2 — the scoping, in isolation" do
    test "returns only the ids of levels present in the snapshot" do
      level_map = %{{"a", 1} => "id-a1", {"a", 2} => "id-a2", {"b", 1} => "id-b1"}

      stations = [
        %{"normalizedName" => "a", "levels" => [%{"level" => 1}]},
        %{"normalizedName" => "b", "levels" => [%{"level" => 1}]}
      ]

      assert Sync.snapshot_level_ids(stations, level_map) |> Enum.sort() == ["id-a1", "id-b1"]
    end

    test "an empty snapshot authorises deleting nothing" do
      assert Sync.snapshot_level_ids([], %{{"a", 1} => "id-a1"}) == []
    end

    test "a station with no levels contributes nothing" do
      # `sanitize_levels/1` should always leave a list, but a station whose levels
      # key is missing must not raise here.
      stations = [%{"normalizedName" => "a", "levels" => []}, %{"normalizedName" => "b"}]

      assert Sync.snapshot_level_ids(stations, %{{"a", 1} => "id-a1"}) == []
    end

    test "ignores snapshot levels with no matching row in the table" do
      stations = [%{"normalizedName" => "a", "levels" => [%{"level" => 1}, %{"level" => 99}]}]

      assert Sync.snapshot_level_ids(stations, %{{"a", 1} => "id-a1"}) == ["id-a1"]
    end
  end
end
