defmodule EftBuddy.Repo.Migrations.AddHistoricalPricesToItemPrices do
  use Ecto.Migration

  @moduledoc """
  Per-mode flea-market price history for the item-detail / flea-card
  sparkline.

  tarkov.dev's JSON API exposes only *spot* flea prices — there is no
  price time series anywhere in it. So rather than back-filling history
  from an external source, `EftBuddy.Items.Sync` accumulates it: every
  price refresh appends the item's current `lastLowPrice` (with a
  timestamp) to this column and trims it to a bounded window. Stored as
  a compact JSON array of `{"price", "timestamp"}` points, keyed by the
  same `(item_id, game_mode)` row the other flea columns live on.

  Stored as `jsonb` (Ecto `:map` migration type) holding a JSON array;
  the schema types the field as `{:array, :map}`. Nullable — items with
  no accumulated history yet (quest items, brand-new items, gaps before
  the first refresh) simply keep NULL and the UI treats it as
  "no graph yet".
  """

  def change do
    alter table(:item_prices) do
      add :historical_prices, :map
    end
  end
end
