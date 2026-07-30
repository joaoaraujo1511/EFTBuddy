defmodule EftBuddy.Repo.Migrations.AddSidesAndCategoriesToMapSpawns do
  @moduledoc """
  Keep the raw `sides` / `categories` the API returns for each spawn point.

  Whether a boss-category point renders as a boss pin or a scav pin depends on
  a read-side join (does any boss claim its zone?), so the answer can't be
  baked into `spawn_type` at sync time without coupling the boss and spawn
  passes — and any change to the rule would need a full re-sync to take effect.
  """

  use Ecto.Migration

  def change do
    alter table(:map_spawns) do
      add :sides, {:array, :string}, null: false, default: []
      add :categories, {:array, :string}, null: false, default: []
    end
  end
end
