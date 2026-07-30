defmodule EftBuddy.Repo.Migrations.AddDetailsToMaps do
  use Ecto.Migration

  @moduledoc """
  Promotes `maps` from the bare name/slug row that `Tasks.Sync` seeded
  into a first-class entity populated by the dedicated `Maps.Sync`
  (which pulls the full tarkov.dev `maps` query).

  All columns are nullable: the table predates this feature, existing
  rows (written by the Tasks sync) carry only `name` / `normalized_name`
  / `external_id` and stay valid until the first `Maps.Sync` run
  enriches them.
  """

  def change do
    alter table(:maps) do
      # tarkov.dev `Map.tarkovDataId` — the legacy numeric id used by
      # some community tooling; kept for cross-referencing.
      add :tarkov_data_id, :string
      # `Map.nameId` — the internal location id (e.g. "Sandbox").
      add :name_id, :string

      add :wiki, :string
      add :description, :text

      # Interactive-map SVG asset URL (e.g.
      # https://assets.tarkov.dev/maps/svg/Customs.svg). Sourced from
      # tarkov.dev's `maps.json` at sync time, since the GraphQL API
      # doesn't expose map imagery. Nullable: newer maps without a
      # community SVG (Icebreaker, The Lab, …) simply have no image.
      add :svg_path, :string

      # `Map.enemies` is a free-text list ("Scavs", "Tagilla", …).
      add :enemies, {:array, :string}, null: false, default: []

      add :raid_duration, :integer
      add :players, :string
      add :min_player_level, :integer
      add :max_player_level, :integer
      # Min PMC level required to use the access keys (separate from the
      # map's own level gate).
      add :access_keys_min_player_level, :integer
    end
  end
end
