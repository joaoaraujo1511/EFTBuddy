defmodule EftBuddy.Repo.Migrations.AddGameModeToBarters do
  use Ecto.Migration

  @moduledoc """
  ~6% of barter recipes genuinely differ between modes. The
  tarkov.dev API assigns *mode-specific* barter ids (the regular and
  PVE id sets are fully disjoint), so `external_id` stays globally
  unique even with both modes loaded — no composite key needed. We
  add `game_mode` purely so the item-detail panel can show the
  acquisition routes for the active mode.

  Barter *child* rows (required/reward items) inherit their mode via
  the barter FK. Crafts are NOT tagged: they are byte-identical across
  modes, so we keep the single `regular` set.

  Existing rows backfill to `"regular"` via the column default.
  """

  def change do
    alter table(:items_barters) do
      add :game_mode, :string, null: false, default: "regular"
    end

    create index(:items_barters, [:game_mode])
  end
end
