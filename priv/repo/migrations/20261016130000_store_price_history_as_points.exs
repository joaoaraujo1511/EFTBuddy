defmodule EftBuddy.Repo.Migrations.StorePriceHistoryAsPoints do
  @moduledoc """
  Flea price history moves from a JSONB array on each `item_prices` row to an
  append-only table with one row per price change (audit M2).

  Every ten-minute tick used to read every row's array back (about 1.5 s per
  mode) and rewrite all of them, about 11k rows of up to 192 points. Measured on
  the Pi, that was roughly 6.5 GB a day written to the microSD card for a
  125 MB database. A point is now added only when an item's price changes
  (~170 per mode per tick), and a point is removed once it is older than the
  window, unless it is the item's latest point before the window, which is
  what the sparkline starts from.

  The backfill keeps only the points where the price changed, so existing
  sparklines carry over unchanged.
  """
  use Ecto.Migration

  def up do
    create table(:item_price_points) do
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :game_mode, :string, null: false
      add :observed_at, :naive_datetime, null: false
      add :price, :integer, null: false
    end

    create index(:item_price_points, [:game_mode, :item_id, :observed_at])

    execute """
    INSERT INTO item_price_points (item_id, game_mode, observed_at, price)
    SELECT item_id, game_mode, to_timestamp(ts / 1000.0) AT TIME ZONE 'UTC', price
    FROM (
      SELECT p.item_id, p.game_mode,
             (point->>'timestamp')::bigint AS ts,
             (point->>'price')::bigint AS price,
             lag((point->>'price')::bigint) OVER (
               PARTITION BY p.item_id, p.game_mode ORDER BY (point->>'timestamp')::bigint
             ) AS previous
      FROM item_prices p, jsonb_array_elements(coalesce(p.historical_prices, '[]'::jsonb)) AS point
      WHERE jsonb_typeof(p.historical_prices) = 'array' AND point ? 'price' AND point ? 'timestamp'
    ) series
    WHERE previous IS DISTINCT FROM price
    """

    alter table(:item_prices) do
      remove :historical_prices
    end
  end

  def down do
    alter table(:item_prices) do
      add :historical_prices, :map
    end

    execute """
    UPDATE item_prices p
    SET historical_prices = s.points
    FROM (
      SELECT item_id, game_mode,
             jsonb_agg(
               jsonb_build_object(
                 'price', price,
                 'timestamp', (extract(epoch FROM observed_at) * 1000)::bigint
               ) ORDER BY observed_at
             ) AS points
      FROM item_price_points
      GROUP BY item_id, game_mode
    ) s
    WHERE s.item_id = p.item_id AND s.game_mode = p.game_mode
    """

    drop table(:item_price_points)
  end
end
