defmodule EftBuddy.Repo.Migrations.DropChangeLast48h do
  use Ecto.Migration

  # The 48h flea price-change metric (absolute + percent) was dropped from
  # the UI in favour of a 24h-only trend cue (current low vs 24h average),
  # so the backing columns are no longer read or written anywhere. Drop
  # them from both the legacy `items` mirror and the per-mode
  # `item_prices` snapshot.
  #
  # `remove/2` carries the column type so the migration is reversible: a
  # rollback re-adds the (empty) float columns, which the next sync would
  # simply leave NULL.
  def change do
    alter table(:items) do
      remove :change_last_48h, :float
      remove :change_last_48h_percent, :float
    end

    alter table(:item_prices) do
      remove :change_last_48h, :float
      remove :change_last_48h_percent, :float
    end
  end
end
