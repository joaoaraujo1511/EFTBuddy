defmodule EftBuddy.Repo.Migrations.AddChangeLast48hPercentToItemPrices do
  @moduledoc """
  tarkov.dev's own 48-hour flea price change (`changeLast48hPercent`), per
  mode. The Flea page used to compute a "24h change" from our own price
  history, which only spans about 32 hours and fell back to its oldest point,
  so the label rarely matched the window.
  """
  use Ecto.Migration

  def change do
    alter table(:item_prices) do
      add :change_last_48h_percent, :float
    end
  end
end
