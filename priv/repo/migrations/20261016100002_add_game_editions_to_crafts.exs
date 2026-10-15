defmodule EftBuddy.Repo.Migrations.AddGameEditionsToCrafts do
  @moduledoc """
  The game editions a craft is limited to (tarkov.dev `gameEditions`, e.g.
  `["edge_of_darkness", "eod_tue_edition"]`). Empty means every edition. The
  field used to be dropped, so an edition-locked craft was shown to everyone
  without a word.
  """
  use Ecto.Migration

  def change do
    alter table(:items_crafts) do
      add :game_editions, {:array, :string}, null: false, default: []
    end
  end
end
