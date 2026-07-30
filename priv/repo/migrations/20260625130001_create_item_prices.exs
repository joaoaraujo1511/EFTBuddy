defmodule EftBuddy.Repo.Migrations.CreateItemPrices do
  use Ecto.Migration

  @moduledoc """
  Per-mode economy snapshot for every item.

  Item *entities* are identical across PVP/PVE (same id set), but the
  economy is not: flea prices differ for ~71% of items, and even
  `basePrice` diverges for a few hundred (PVE re-tunes some values).
  Because there is exactly one `items` row per item, the two modes'
  prices can't both live on that row — they live here, keyed by
  `(item_id, game_mode)`.

  The volatile flea columns on `items` itself are kept as the
  `regular` snapshot (so existing readers and the periodic price
  refresh keep working), but all *mode-aware* reads (flea market list,
  item detail, price sort) go through this table.

  `base_price` is carried here too so the flea-market sort fallback
  (`coalesce(last_low_price, base_price)`) is correct per mode.
  """

  def change do
    create table(:item_prices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :game_mode, :string, null: false, default: "regular"

      add :base_price, :integer
      add :last_low_price, :integer
      add :avg_24h_price, :integer
      add :low_24h_price, :integer
      add :high_24h_price, :integer
      add :change_last_48h, :float
      add :change_last_48h_percent, :float

      add :item_id,
          references(:items, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    # One price row per item per mode; the sync upserts on this target.
    create unique_index(:item_prices, [:item_id, :game_mode])

    # The flea-market listing orders by `last_low_price` within a mode
    # and filters out NULL prices, so a `(game_mode, last_low_price)`
    # index keeps that query off a full scan.
    create index(:item_prices, [:game_mode, :last_low_price])
  end
end
