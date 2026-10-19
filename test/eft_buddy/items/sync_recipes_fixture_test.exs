defmodule EftBuddy.Items.SyncRecipesFixtureTest do
  @moduledoc """
  Runs the real barter and craft syncs against trimmed live tarkov.dev
  documents (test/fixtures/tarkov), then renders the result on the Items page.

  Pins three things upstream sends that used to be lost: fractional ingredient
  counts (audit M8), quest-item ingredients upstream doesn't define yet, and a
  craft's game-edition lock (L27).
  """
  use EftBuddyWeb.ConnCase, async: false

  import EftBuddy.Fixtures, only: [item: 1]
  import Phoenix.LiveViewTest

  alias EftBuddy.Items.{Barter, BarterRequiredItem, Craft, CraftRequiredItem}
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.TarkovFixtures

  import Ecto.Query

  @water_filter "5d1b385e86f774252167b98a"

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    TarkovFixtures.stub()

    # Regular items exist; quest items deliberately don't, which is what an
    # ingredient upstream hasn't defined yet looks like to the sync.
    for {id, it} <- TarkovFixtures.doc("regular", "items")["data"]["items"] do
      item(%{external_id: id, normalized_name: it["normalizedName"], name: it["normalizedName"]})
    end

    {:ok, _} = EftBuddy.Hideout.Sync.do_run()
    {:ok, _} = EftBuddy.Items.Sync.run_barters_and_crafts()
    :ok
  end

  defp raw_crafts, do: TarkovFixtures.doc("regular", "crafts")["data"]
  defp craft(external_id), do: Repo.get_by!(Craft, external_id: external_id)

  test "fractional ingredient counts are stored as upstream sends them" do
    for b <- TarkovFixtures.doc("regular", "barters")["data"],
        r <- b["requiredItems"],
        r["count"] != trunc(r["count"]) do
      barter = Repo.get_by!(Barter, external_id: b["id"])

      counts =
        Repo.all(
          from rq in BarterRequiredItem, where: rq.barter_id == ^barter.id, select: rq.count
        )

      assert Enum.any?(counts, &Decimal.equal?(&1, Decimal.from_float(r["count"])))
    end

    filter_craft =
      Enum.find(raw_crafts(), fn c ->
        Enum.any?(c["requiredItems"], &(&1["item"] == @water_filter))
      end)

    counts =
      Repo.all(
        from rq in CraftRequiredItem,
          join: i in assoc(rq, :item),
          where: rq.craft_id == ^craft(filter_craft["id"]).id and i.external_id == @water_filter,
          select: rq.count
      )

    assert [count] = counts
    assert Decimal.equal?(count, Decimal.new("0.66"))
  end

  test "a quest item upstream doesn't define yet is kept as an unresolved ingredient" do
    c = Enum.find(raw_crafts(), &(&1["requiredQuestItems"] not in [nil, []]))
    row = craft(c["id"])

    unresolved =
      Repo.all(
        from rq in CraftRequiredItem,
          where: rq.craft_id == ^row.id and is_nil(rq.item_id),
          select: rq.unresolved_external_id
      )

    assert Enum.sort(unresolved) ==
             c["requiredQuestItems"] |> Enum.map(& &1["item"]) |> Enum.sort()
  end

  test "a craft keeps its game-edition lock" do
    c = Enum.find(raw_crafts(), &(&1["gameEditions"] not in [nil, []]))
    assert craft(c["id"]).game_editions == c["gameEditions"]
  end

  test "the Items page shows fractions, unknown quest items and the edition badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/items")

    expand = fn external_id ->
      item = Repo.get_by!(EftBuddy.Items.Item, external_id: external_id)
      render_hook(view, "toggle_expand", %{"id" => item.id})
    end

    assert expand.(@water_filter) =~ "×0.66"

    quest_craft = Enum.find(raw_crafts(), &(&1["requiredQuestItems"] not in [nil, []]))
    assert expand.(quest_craft["productItem"]["item"]) =~ "Unknown quest item"

    edition_craft = Enum.find(raw_crafts(), &(&1["gameEditions"] not in [nil, []]))
    assert expand.(edition_craft["productItem"]["item"]) =~ "Limited to certain game editions"
  end
end
