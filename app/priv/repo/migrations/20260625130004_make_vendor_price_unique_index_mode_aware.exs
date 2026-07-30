defmodule EftBuddy.Repo.Migrations.MakeVendorPriceUniqueIndexModeAware do
  use Ecto.Migration

  @moduledoc """
  `sell_for` / `buy_for` carry a pre-existing `(item_id, vendor_id)`
  UNIQUE index (added in `20260518120000_add_price_indexes`). With
  per-mode prices, the same `(item_id, vendor_id)` legitimately appears
  once per game mode (e.g. Therapist sells an item in both PVP and PVE),
  so the uniqueness key has to include `game_mode` — otherwise the PVE
  price pass collides with the regular rows already written for the same
  item+vendor (`unique_violation` on `sell_for_item_id_vendor_id_index`).
  """

  def change do
    drop unique_index(:sell_for, [:item_id, :vendor_id])
    drop unique_index(:buy_for, [:item_id, :vendor_id])

    create unique_index(:sell_for, [:item_id, :vendor_id, :game_mode])
    create unique_index(:buy_for, [:item_id, :vendor_id, :game_mode])
  end
end
