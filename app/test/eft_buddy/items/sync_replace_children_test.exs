defmodule EftBuddy.Items.SyncReplaceChildrenTest do
  @moduledoc """
  Characterisation tests for `EftBuddy.Items.Sync.replace_children/5`.

  This is the most destructive code path in the application: it issues an
  unguarded `DELETE` over child rows on every items sync. `Sync.Helpers`'
  `cleanup_safe?/3` guard is well tested in its own right, but it protects the
  PARENT prune only — these tests pin the other half of the contract, that the
  child delete is scoped to the parents the current upstream snapshot actually
  carried.

  Why that matters: if the delete is scoped to the whole table instead, then on a
  truncated upstream response the guard refuses to prune the missing parents while
  their children have already been wiped — leaving barters and crafts that render
  as having no ingredients at all. The UI presents that as fact, and nothing in the
  app can detect it.

  Every test drives `replace_children/5` with the two things a real caller has in
  hand — the `external_id => id` map read back from the whole table, and this
  run's snapshot rows — rather than a pre-computed id list. That is deliberate:
  the original defect was not in the delete, it was at the call site, so a test
  that hands over an already-correct id list cannot catch it.
  """
  use EftBuddy.DataCase, async: true

  import EftBuddy.Fixtures

  alias EftBuddy.Items.BarterRequiredItem
  alias EftBuddy.Items.Sync

  defp required_ids(barter_id) do
    BarterRequiredItem
    |> where(barter_id: ^barter_id)
    |> select([r], r.item_id)
    |> Repo.all()
  end

  # One barter that the next snapshot will carry, one that it will not.
  defp two_barters_with_children do
    trader = trader()
    kept_item = item(%{name: "Kept ingredient"})
    stale_item = item(%{name: "Stale ingredient"})

    in_snapshot = barter(%{external_id: "in-snapshot", trader_id: trader.id})
    absent = barter(%{external_id: "absent-upstream", trader_id: trader.id})

    barter_required(%{barter_id: in_snapshot.id, item_id: kept_item.id})
    barter_required(%{barter_id: absent.id, item_id: stale_item.id})

    %{in_snapshot: in_snapshot, absent: absent, kept_item: kept_item, stale_item: stale_item}
  end

  # What `fetch_barter_id_map/2` returns: the WHOLE table, both barters, which is
  # what made the unscoped version so destructive.
  defp whole_table_id_map(%{in_snapshot: in_snapshot, absent: absent}) do
    %{"in-snapshot" => in_snapshot.id, "absent-upstream" => absent.id}
  end

  # A snapshot row as the sync builds it, pre-upsert.
  defp snapshot_rows(external_ids), do: Enum.map(external_ids, &%{external_id: &1})

  defp child_row(barter_id, item_id, count) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %{
      barter_id: barter_id,
      item_id: item_id,
      count: count,
      quantity: count,
      inserted_at: now,
      updated_at: now
    }
  end

  test "replaces the children of parents in the snapshot" do
    barters = two_barters_with_children()
    %{in_snapshot: in_snapshot, stale_item: replacement} = barters

    Sync.replace_children(
      BarterRequiredItem,
      :barter_id,
      whole_table_id_map(barters),
      snapshot_rows(["in-snapshot"]),
      [child_row(in_snapshot.id, replacement.id, 2)]
    )

    # The old child is gone and the fresh one is in its place.
    assert required_ids(in_snapshot.id) == [replacement.id]
  end

  test "leaves the children of parents ABSENT from the snapshot untouched" do
    # THIS IS THE REGRESSION, and the whole reason the function derives its own
    # scope. The id map handed in carries both barters — that is unavoidable, it is
    # read back from the table — while the snapshot carries only one. The delete
    # must reach exactly one of them.
    #
    # `rows` MUST be non-empty here. An earlier version of this test passed `[]`,
    # which matches the protective short-circuit clause below and issues no SQL at
    # all, so the assertion was trivially true and would have passed even if the
    # delete had wiped the whole table. A regression test that cannot fail is worse
    # than no test, because it reads as coverage.
    barters = two_barters_with_children()

    %{in_snapshot: in_snapshot, absent: absent, stale_item: stale_item, kept_item: kept_item} =
      barters

    Sync.replace_children(
      BarterRequiredItem,
      :barter_id,
      whole_table_id_map(barters),
      snapshot_rows(["in-snapshot"]),
      [child_row(in_snapshot.id, kept_item.id, 3)]
    )

    assert required_ids(absent.id) == [stale_item.id],
           "children of a parent the snapshot did not carry must survive"

    # And the delete did happen for the parent that WAS in the snapshot, which is
    # what proves the query ran at all.
    assert required_ids(in_snapshot.id) == [kept_item.id]
  end

  test "clears a snapshot parent whose own children vanished" do
    # This is the case that rules out deriving the scope from `rows`.
    # `replace_children/5` is called ONCE for the whole snapshot, so when barter A
    # loses all its children while barter B keeps some, `rows` carries only B's.
    # A's stale children must still go — only the snapshot's parent list can say so.
    barters = two_barters_with_children()
    %{in_snapshot: keeps_children, absent: loses_children, kept_item: item} = barters

    # BOTH barters are in this snapshot; only one contributed child rows.
    Sync.replace_children(
      BarterRequiredItem,
      :barter_id,
      whole_table_id_map(barters),
      snapshot_rows(["in-snapshot", "absent-upstream"]),
      [child_row(keeps_children.id, item.id, 1)]
    )

    assert required_ids(keeps_children.id) == [item.id]
    assert required_ids(loses_children.id) == []
  end

  test "an entirely empty child set is treated as untrustworthy and deletes nothing" do
    # `rows == []` means the WHOLE snapshot yielded no child rows, which for real
    # data is impossible — every barter has ingredients. It signals a truncated or
    # bogus upstream response, so the safe reading is to keep what we have rather
    # than empty every recipe in the database. Deliberate behaviour, pinned here so
    # nobody "optimises" the clause away.
    barters = two_barters_with_children()
    %{in_snapshot: in_snapshot, absent: absent} = barters

    Sync.replace_children(
      BarterRequiredItem,
      :barter_id,
      whole_table_id_map(barters),
      snapshot_rows(["in-snapshot", "absent-upstream"]),
      []
    )

    assert length(required_ids(in_snapshot.id)) == 1
    assert length(required_ids(absent.id)) == 1
  end

  test "an empty snapshot deletes nothing even with child rows to insert" do
    # Belt and braces on the scoping: if upstream carried no parents at all, no
    # existing child row is in scope, whatever `rows` says.
    barters = two_barters_with_children()
    %{in_snapshot: in_snapshot, absent: absent, kept_item: item} = barters

    Sync.replace_children(
      BarterRequiredItem,
      :barter_id,
      whole_table_id_map(barters),
      [],
      [child_row(in_snapshot.id, item.id, 1)]
    )

    assert length(required_ids(absent.id)) == 1
  end

  test "a badly truncated snapshot cannot reach the rest of the table" do
    # The shape of the real failure: upstream returns HTTP 200 with a fraction of
    # the barters. The id map still holds every barter in the table, so an unscoped
    # delete strips them all; `cleanup_stale_barters/2` then refuses to prune the
    # missing parents, and the result is hundreds of ingredient-less recipes.
    trader = trader()
    ingredient = item(%{name: "Ingredient"})

    survivors =
      for n <- 1..20 do
        b = barter(%{external_id: "barter-#{n}", trader_id: trader.id})
        barter_required(%{barter_id: b.id, item_id: ingredient.id})
        b
      end

    id_map = Elixir.Map.new(survivors, &{&1.external_id, &1.id})
    [first | rest] = survivors

    Sync.replace_children(
      BarterRequiredItem,
      :barter_id,
      id_map,
      snapshot_rows(["barter-1"]),
      [child_row(first.id, ingredient.id, 5)]
    )

    for b <- rest do
      assert required_ids(b.id) == [ingredient.id],
             "a 1-of-20 snapshot must not authorise deleting the other 19 barters' children"
    end
  end

  describe "snapshot_parent_ids/2 — the scoping, in isolation" do
    test "returns only the ids of parents present in the snapshot" do
      id_map = %{"a" => 1, "b" => 2, "absent-upstream" => 3}

      assert Sync.snapshot_parent_ids(id_map, snapshot_rows(["a", "b"])) |> Enum.sort() == [1, 2]
    end

    test "an empty snapshot authorises deleting nothing" do
      assert Sync.snapshot_parent_ids(%{"a" => 1, "b" => 2}, []) == []
    end

    test "ignores snapshot rows with no matching row in the table" do
      # Defensive: an external_id that somehow failed to upsert contributes no id
      # rather than a nil that would blow up the `in ^chunk` query.
      assert Sync.snapshot_parent_ids(%{"a" => 1}, snapshot_rows(["a", "ghost"])) == [1]
    end
  end
end
