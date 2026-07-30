defmodule EftBuddy.Repo.Migrations.AddMinLevelForFleaToItems do
  use Ecto.Migration

  def change do
    alter table(:items) do
      # Per-item minimum PMC level to list/trade the item on the flea
      # market (tarkov.dev Item.minLevelForFlea). NULL when unspecified;
      # the flea page falls back to the category value, then the global
      # flea unlock level.
      add :min_level_for_flea, :integer
    end
  end
end
