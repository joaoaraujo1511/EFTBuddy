defmodule EftBuddy.Repo.Migrations.AddFoundInRaidToHideoutItemRequirements do
  @moduledoc """
  Whether a hideout upgrade needs the item found in raid (tarkov.dev
  `attributes.foundInRaid`; 76 of 317 requirements today). It was dropped, so
  nothing told a player that a bought item wouldn't count.
  """
  use Ecto.Migration

  def change do
    alter table(:hideout_item_requirements) do
      add :found_in_raid, :boolean, null: false, default: false
    end
  end
end
