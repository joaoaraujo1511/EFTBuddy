defmodule EftBuddy.Tasks.SyncFixtureTest do
  @moduledoc """
  Runs the real `EftBuddy.Tasks.Sync` against trimmed live tarkov.dev
  documents (test/fixtures/tarkov). Before these, Tasks.Sync had no tests.

  The sandbox never commits, so a deferred constraint would never be checked;
  `SET CONSTRAINTS ALL IMMEDIATE` makes the test check it before it ends.
  """
  use EftBuddy.DataCase, async: false

  alias EftBuddy.Hideout.Skill
  alias EftBuddy.Maps.Map, as: GameMap
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.Tasks.Sync
  alias EftBuddy.Tasks.Task
  alias EftBuddy.TarkovFixtures

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    TarkovFixtures.stub()
    :ok
  end

  defp check_deferred_constraints!, do: Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

  defp slug(external_id, mode \\ "regular") do
    Repo.one!(
      from t in Task,
        where: t.external_id == ^external_id and t.game_mode == ^mode,
        select: t.normalized_name
    )
  end

  test "a sync over the fixtures writes every task for both modes" do
    assert {:ok, _} = Sync.do_run()

    for mode <- ["regular", "pve"] do
      expected = map_size(TarkovFixtures.doc(mode, "tasks")["data"]["tasks"])
      assert Repo.aggregate(from(t in Task, where: t.game_mode == ^mode), :count) == expected
    end
  end

  test "tasks swapping names upstream no longer abort the run" do
    # REGRESSION (audit H8). The Punisher quests swapped names upstream, and the
    # plain unique index on (normalized_name, game_mode) rejected the first
    # renamed row, rolling back every run for that mode.
    assert {:ok, _} = Sync.do_run()

    [a, b | _] =
      TarkovFixtures.doc("regular", "tasks")["data"]["tasks"]
      |> Map.values()
      |> Enum.sort_by(& &1["id"])

    # Store each task under the other's slug, as if upstream were about to swap
    # them back.
    for {id, to} <- [
          {a["id"], "parked"},
          {b["id"], a["normalizedName"]},
          {a["id"], b["normalizedName"]}
        ] do
      from(t in Task, where: t.external_id == ^id and t.game_mode == "regular")
      |> Repo.update_all(set: [normalized_name: to])
    end

    assert {:ok, _} = Sync.do_run()
    check_deferred_constraints!()

    assert slug(a["id"]) == a["normalizedName"]
    assert slug(b["id"]) == b["normalizedName"]
  end

  test "a map whose id upstream rotated doesn't abort the run" do
    # REGRESSION (audit M9). Seeding maps keyed only on external_id still hit
    # the slug index for a map whose id had rotated.
    # A map a fixture task references, so the task sync seeds it.
    tasks = TarkovFixtures.doc("regular", "tasks")["data"]["tasks"] |> Map.values()
    referenced = MapSet.new(for t <- tasks, t["map"], do: t["map"])
    maps = TarkovFixtures.doc("regular", "maps")["data"]["maps"]
    map = Enum.find_value(referenced, &maps[&1])
    assert map, "the fixtures should include a map a task references"

    Repo.insert!(%GameMap{
      external_id: "an-older-id",
      name: "Stale name",
      normalized_name: map["normalizedName"]
    })

    assert {:ok, _} = Sync.do_run()
  end

  test "task skills are stored translated, and orphaned raw-enum skills are removed" do
    # Audit H9: rows like "sniper" were created from untranslated enum keys.
    stale = Repo.insert!(%Skill{name: "Sniper", normalized_name: "sniper"})

    assert {:ok, _} = Sync.do_run()

    refute Repo.get(Skill, stale.id)
    assert Repo.get_by(Skill, normalized_name: "bolt-action-rifles")
  end
end
