defmodule EftBuddy.Repo.Migrations.CreateGameSettings do
  use Ecto.Migration

  @moduledoc """
  A tiny key/value store for global game constants that come from the
  tarkov.dev API but aren't tied to a single item/task/map row.

  Today it holds exactly one key — `flea_market_min_player_level`, the
  PMC level at which the flea market unlocks (`data.fleaMarket
  .minPlayerLevel`, 15 today). The flea lock floors every item's
  effective level at this value, so sourcing it from the API (rather
  than hard-coding 15) keeps the gate correct if BSG ever re-tunes it.

  DB-backed (rather than app-env / :persistent_term) so the value is
  consistent across a multi-node cluster where only the elected node
  runs the sync.
  """

  def change do
    create table(:game_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :int_value, :integer

      timestamps()
    end

    create unique_index(:game_settings, [:key])
  end
end
