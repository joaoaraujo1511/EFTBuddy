defmodule EftBuddy.Items.PerModePricesTest do
  @moduledoc """
  Regression coverage for the per-mode price storage.

  The `sell_for` / `buy_for` tables carry a unique index that must
  include `game_mode`: the same `(item_id, vendor_id)` legitimately
  appears once per game mode, and the dual-mode sync writes the regular
  rows before the PVE rows. Before the index was made mode-aware, the
  PVE price pass blew up with a `unique_violation` on
  `sell_for_item_id_vendor_id_index`.
  """
  use EftBuddy.DataCase, async: true

  alias EftBuddy.Fixtures
  alias EftBuddy.Items
  alias EftBuddy.Items.SellFor
  alias EftBuddy.Repo

  test "the same item+vendor can have a sell price in both game modes" do
    item = Fixtures.item(%{last_low_price: 1_000})
    vendor = Fixtures.vendor()

    Fixtures.sell_for(%{item_id: item.id, vendor_id: vendor.id, game_mode: "regular"})

    # This is the insert that used to violate the (item_id, vendor_id)
    # unique index — it must succeed now that the index is mode-aware.
    assert %SellFor{} =
             Fixtures.sell_for(%{item_id: item.id, vendor_id: vendor.id, game_mode: "pve"})

    assert Repo.aggregate(SellFor, :count) == 2
  end

  test "the unique index still rejects a duplicate within a single mode" do
    item = Fixtures.item()
    vendor = Fixtures.vendor()

    Fixtures.sell_for(%{item_id: item.id, vendor_id: vendor.id, game_mode: "regular"})

    assert_raise Ecto.ConstraintError, fn ->
      Fixtures.sell_for(%{item_id: item.id, vendor_id: vendor.id, game_mode: "regular"})
    end
  end

  test "flea market and item detail return the active mode's prices" do
    cat = Fixtures.category()

    item =
      Fixtures.item(%{name: "Mode Probe", category_id: cat.id, last_low_price: 1_111})

    # A divergent PVE flea price for the same item.
    Fixtures.item_price(%{item_id: item.id, game_mode: "pve", last_low_price: 9_999})

    [pvp] = Items.list_flea_market_items(query: "Mode Probe", game_mode: :pvp)
    [pve] = Items.list_flea_market_items(query: "Mode Probe", game_mode: :pve)

    assert pvp.last_low_price == 1_111
    assert pve.last_low_price == 9_999
  end
end
