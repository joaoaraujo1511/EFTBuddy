defmodule EftBuddy.Repo.Migrations.AddPositionToMapBosses do
  @moduledoc """
  Records the API's own ordering of a map's boss entries, which puts the
  headline boss first (Reshala on Customs, Killa on Interchange).

  The cards and index chips group these rows by boss identity and promise
  "first appearance" order, which needs a stable sort key. `inserted_at` can't
  serve: it is second-precision, so an entire sync shares one timestamp and the
  tiebreak falls to a random UUID primary key.
  """

  use Ecto.Migration

  def change do
    alter table(:map_bosses) do
      add :position, :integer, null: false, default: 0
    end

    create index(:map_bosses, [:map_id, :position])
  end
end
