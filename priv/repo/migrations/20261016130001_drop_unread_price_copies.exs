defmodule EftBuddy.Repo.Migrations.DropUnreadPriceCopies do
  @moduledoc """
  Drops two copies of price data that were written on every sync and read by
  nothing (audit L2):

    * `sell_for`: trader sell offers, about 30k rows per mode deleted and
      re-inserted every 12 hours;
    * the price columns on `items` (`last_low_price` and the three 24h
      columns), a regular-mode mirror rewritten every 10 minutes after every
      read had moved to the per-mode `item_prices`.

  `items.base_price` stays: listings fall back to it when an item has no price
  row. Rolling back restores the schema only; the data was never read.
  """
  use Ecto.Migration

  @columns [:last_low_price, :avg_24h_price, :low_24h_price, :high_24h_price]

  def up do
    drop table(:sell_for)

    alter table(:items) do
      for column <- @columns, do: remove(column)
    end
  end

  def down do
    alter table(:items) do
      for column <- @columns, do: add(column, :integer)
    end

    create index(:items, [:last_low_price],
             where: "last_low_price IS NOT NULL",
             name: :items_last_low_price_not_null_index
           )

    create table(:sell_for, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :price, :integer, null: false
      add :price_rub, :integer
      add :currency, :string, null: false
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all)
      add :vendor_id, references(:vendors, type: :binary_id)
      add :game_mode, :string, null: false, default: "regular"

      timestamps()
    end

    create index(:sell_for, [:item_id])
    create index(:sell_for, [:item_id, :game_mode])
    create unique_index(:sell_for, [:item_id, :vendor_id, :game_mode])
  end
end
