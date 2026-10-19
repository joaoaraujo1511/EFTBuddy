defmodule EftBuddy.Items.SyncQuestItemsFixtureTest do
  @moduledoc """
  Runs the real items step, which chains the quest-item sync, against the
  tarkov.dev fixtures.

  Nothing ran the quest-item upsert before, so when the price columns on `items`
  were dropped it went on writing them, and every run crashed with "unknown field
  `:avg_24h_price`". The crash is swallowed by design (a quest-item failure must
  not roll back the regular items), so only the missing rows showed it.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Items.{Item, Sync}
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.TarkovFixtures

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    TarkovFixtures.stub()
    :ok
  end

  test "the items step writes every quest item upstream lists" do
    expected = TarkovFixtures.doc("regular", "tasks")["data"]["questItems"] |> Map.keys()

    capture_log(fn -> assert {:ok, _} = Sync.run_items() end)

    stored =
      Repo.all(from i in Item, where: i.is_quest_item == true, select: i.external_id)

    assert Enum.sort(stored) == Enum.sort(expected)
    assert Reporter.status()["QuestItemsSync"].outcome == :ok
  end
end
