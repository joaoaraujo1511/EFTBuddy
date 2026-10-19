defmodule EftBuddy.UpstreamFirAndPriceChangeTest do
  @moduledoc """
  Two upstream fields that used to be dropped, driven through the real syncs
  with trimmed live tarkov.dev documents:

    * a hideout requirement's `foundInRaid` flag (76 of 317 requirements live);
    * an item's own 48-hour flea change, `changeLast48hPercent`, which replaced
      a "24h" figure computed from our own ~32h price history.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Ecto.Query
  import EftBuddy.Fixtures, only: [item: 1]
  import Phoenix.LiveViewTest

  alias EftBuddy.Hideout.ItemRequirement
  alias EftBuddy.Items.{Item, ItemPrice}
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.TarkovFixtures

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    TarkovFixtures.stub()
    :ok
  end

  defp fir_requirements do
    for s <- Map.values(TarkovFixtures.doc("regular", "hideout")["data"]),
        l <- s["levels"],
        r <- l["itemRequirements"],
        do: {r["item"], get_in(r, ["attributes", "foundInRaid"]) == true}
  end

  describe "hideout found-in-raid requirements" do
    setup do
      for id <- fir_requirements() |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          do: item(%{external_id: id, normalized_name: id, name: "Item #{id}"})

      {:ok, _} = EftBuddy.Hideout.Sync.do_run()
      :ok
    end

    test "the flag is stored as upstream sends it" do
      expected = Enum.count(fir_requirements(), &elem(&1, 1))
      assert expected > 0

      assert Repo.aggregate(from(r in ItemRequirement, where: r.found_in_raid), :count) ==
               expected
    end

    test "the item panel says the upgrade needs it found in raid", %{conn: conn} do
      {id, true} = Enum.find(fir_requirements(), &elem(&1, 1))
      fir_item = Repo.get_by!(Item, external_id: id)

      {:ok, view, _html} = live(conn, ~p"/items")
      html = render_hook(view, "toggle_expand", %{"id" => fir_item.id})

      # Highlighted the same way task requirements are, by `fir_text/1`.
      assert html =~ ~r{to be <span class="text-rust font-semibold">found in raid</span> for the}
    end
  end

  test "the price tick stores upstream's 48h change per item" do
    raw = TarkovFixtures.doc("regular", "items")["data"]["items"]

    for {id, it} <- raw,
        is_integer(it["lastLowPrice"]),
        do: item(%{external_id: id, normalized_name: id})

    {:ok, _} = EftBuddy.Items.Sync.run_prices()

    {id, it} = Enum.find(raw, fn {_id, it} -> is_number(it["changeLast48hPercent"]) end)
    local = Repo.get_by!(Item, external_id: id)

    stored =
      Repo.one!(
        from p in ItemPrice,
          where: p.item_id == ^local.id and p.game_mode == "regular",
          select: p.change_last_48h_percent
      )

    assert stored == it["changeLast48hPercent"] * 1.0
  end
end
