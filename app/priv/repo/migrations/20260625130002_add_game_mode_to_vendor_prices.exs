defmodule EftBuddy.Repo.Migrations.AddGameModeToVendorPrices do
  use Ecto.Migration

  @moduledoc """
  Trader buy/sell prices also diverge between modes (trader sell for
  ~499 items, buy for ~228), so `sell_for` / `buy_for` gain a
  `game_mode` discriminator. These tables also carry a pre-existing
  `(item_id, vendor_id)` unique index (from `20260518120000`); it is
  made mode-aware in the follow-up migration
  `20260625130004_make_vendor_price_unique_index_mode_aware`. Here we
  only add the column plus a `(item_id, game_mode)` lookup index.

  Existing rows backfill to `"regular"` via the column default.
  """

  def change do
    alter table(:sell_for) do
      add :game_mode, :string, null: false, default: "regular"
    end

    alter table(:buy_for) do
      add :game_mode, :string, null: false, default: "regular"
    end

    create index(:sell_for, [:item_id, :game_mode])
    create index(:buy_for, [:item_id, :game_mode])
  end
end
