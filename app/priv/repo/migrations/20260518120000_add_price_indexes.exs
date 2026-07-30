defmodule EftBuddy.Repo.Migrations.AddPriceIndexes do
  use Ecto.Migration

  @moduledoc """
  Adds indexes that the periodic Sync GenServer relies on:

    * `(item_id)` on `sell_for` / `buy_for` — every sync run filters
      and bulk-deletes price rows by `item_id`. Without this index
      those queries do a sequential scan that gets linearly slower
      as the dataset grows.
    * `(item_id, vendor_id)` unique on `sell_for` / `buy_for` — guards
      against duplicate rows in the (rare but possible) case of two
      Sync processes overlapping. The Sync GenServer is now a cluster
      singleton, but the constraint is a cheap belt-and-braces.
  """

  def change do
    create index(:sell_for, [:item_id])
    create index(:buy_for, [:item_id])

    create unique_index(:sell_for, [:item_id, :vendor_id])
    create unique_index(:buy_for, [:item_id, :vendor_id])
  end
end
