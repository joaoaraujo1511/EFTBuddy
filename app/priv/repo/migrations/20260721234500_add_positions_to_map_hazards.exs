defmodule EftBuddy.Repo.Migrations.AddPositionsToMapHazards do
  use Ecto.Migration

  # Store every position of a hazard group (not just one representative
  # pin) so the viewer can render a whole minefield / sniper zone as a
  # cluster of markers, the way tarkov.dev shows them.
  def change do
    alter table(:map_hazards) do
      add :positions, {:array, :map}, default: []
    end
  end
end
