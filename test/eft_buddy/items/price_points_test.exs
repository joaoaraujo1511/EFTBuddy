defmodule EftBuddy.Items.PricePointsTest do
  @moduledoc """
  Price history as one `item_price_points` row per price change (audit M2).

  It used to be a JSONB array on every `item_prices` row that each ten-minute
  tick read back and rewrote in full: about 6.5 GB a day of writes to the
  Pi's microSD card for a 125 MB database.
  """
  use EftBuddy.DataCase, async: false

  import EftBuddy.Fixtures, only: [item: 1]

  alias EftBuddy.Items
  alias EftBuddy.Items.{ItemPricePoint, Sync}

  defp doc(prices), do: Enum.map(prices, fn {id, p} -> %{"id" => id, "lastLowPrice" => p} end)

  defp points(item),
    do: Repo.all(from pt in ItemPricePoint, where: pt.item_id == ^item.id, select: pt.price)

  setup do
    %{
      a: item(%{external_id: "a", normalized_name: "a"}),
      b: item(%{external_id: "b", normalized_name: "b"})
    }
  end

  test "a point is recorded for a first price and for every change, and nothing else",
       %{a: a, b: b} do
    Sync.refresh_item_prices_flea(Repo, doc([{"a", 100}, {"b", 200}]), "regular")
    assert points(a) == [100] and points(b) == [200]

    # The same prices again: no new rows. This is the write volume the change saves.
    Sync.refresh_item_prices_flea(Repo, doc([{"a", 100}, {"b", 200}]), "regular")
    assert points(a) == [100] and points(b) == [200]

    Sync.refresh_item_prices_flea(Repo, doc([{"a", 150}, {"b", 200}]), "regular")
    assert Enum.sort(points(a)) == [100, 150]
    assert points(b) == [200]
  end

  test "only rows whose flea fields changed are rewritten", %{a: a, b: b} do
    Sync.refresh_item_prices_flea(Repo, doc([{"a", 100}, {"b", 200}]), "regular")

    long_ago = ~N[2026-01-01 00:00:00]
    Repo.update_all(EftBuddy.Items.ItemPrice, set: [updated_at: long_ago])

    summary = Sync.refresh_item_prices_flea(Repo, doc([{"a", 150}, {"b", 200}]), "regular")
    assert summary.upserted == 1

    stamps =
      Repo.all(
        from p in EftBuddy.Items.ItemPrice,
          where: p.game_mode == "regular",
          select: {p.item_id, p.updated_at}
      )
      |> Map.new()

    assert stamps[b.id] == long_ago
    assert stamps[a.id] != long_ago
  end

  test "a price row the full pass created gets its first point on the next tick, unrewritten",
       %{a: a, b: b} do
    # A brand-new item arrives through the 12-hourly full pass, which inserts its
    # spot prices but records no history point. (The fixture's own price rows
    # would make this a conflict, which keeps the flea columns as they were.)
    Repo.delete_all(EftBuddy.Items.ItemPrice)

    full = [
      %{"id" => "a", "basePrice" => 10, "lastLowPrice" => 100},
      %{"id" => "b", "basePrice" => 20, "lastLowPrice" => 200}
    ]

    Sync.upsert_item_prices(Repo, full, %{"a" => a.id, "b" => b.id}, "regular")
    assert points(a) == [] and points(b) == []

    summary = Sync.refresh_item_prices_flea(Repo, doc([{"a", 100}, {"b", 200}]), "regular")

    # Same values, so no row is rewritten, but the sparkline still gets its start.
    assert summary.upserted == 0
    assert points(a) == [100] and points(b) == [200]
  end

  test "an item that drops off the flea gets no point", %{a: a} do
    Sync.refresh_item_prices_flea(Repo, doc([{"a", 100}, {"b", 200}]), "regular")
    Sync.refresh_item_prices_flea(Repo, doc([{"a", nil}, {"b", 200}]), "regular")

    assert points(a) == [100]
  end

  test "points past the window are pruned, except the one the line starts from", %{a: a} do
    window_s = div(ItemPricePoint.window_ms(), 1_000)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    for {price, ago} <- [{10, window_s + 7_200}, {20, window_s + 3_600}, {30, 3_600}] do
      Repo.insert!(%ItemPricePoint{
        item_id: a.id,
        game_mode: "regular",
        price: price,
        observed_at: NaiveDateTime.add(now, -ago, :second)
      })
    end

    Sync.refresh_item_prices_flea(Repo, doc([{"a", 30}, {"b", 200}]), "regular")

    # 10 was superseded before the window opened; 20 is still the price at the
    # window's left edge.
    assert Enum.sort(points(a)) == [20, 30]
  end

  test "listings carry the series oldest first, the same from SQL and per item", %{a: a} do
    Sync.refresh_item_prices_flea(Repo, doc([{"a", 100}, {"b", 200}]), "regular")

    Repo.update_all(ItemPricePoint,
      set: [observed_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -3_600)]
    )

    Sync.refresh_item_prices_flea(Repo, doc([{"a", 150}, {"b", 200}]), "regular")

    [listed] = Items.list_all_items(limit: 100, game_mode: :pvp) |> Enum.filter(&(&1.id == a.id))
    assert Enum.map(listed.historical_prices, & &1["price"]) == [100, 150]

    detail = Items.get_item_details(a.id, :pvp).item
    assert detail.historical_prices == listed.historical_prices
  end
end
