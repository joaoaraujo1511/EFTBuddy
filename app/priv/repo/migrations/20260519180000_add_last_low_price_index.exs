defmodule EftBuddy.Repo.Migrations.AddLastLowPriceIndex do
  use Ecto.Migration

  @moduledoc """
  Index used by the Flea Market listing query, which filters by
  `last_low_price IS NOT NULL` and sorts by `last_low_price DESC`.

  A partial index excluding NULLs keeps the index small (only
  flea-eligible items) and lets Postgres satisfy both the WHERE
  and the ORDER BY from the index alone.
  """

  def change do
    create index(:items, [:last_low_price],
             where: "last_low_price IS NOT NULL",
             name: :items_last_low_price_not_null_index
           )
  end
end
