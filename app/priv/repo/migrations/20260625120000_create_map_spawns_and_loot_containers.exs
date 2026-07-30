defmodule EftBuddy.Repo.Migrations.CreateMapSpawnsAndLootContainers do
  use Ecto.Migration

  def change do
    # PMC / boss spawn points (positioned). The API returns one row per
    # physical spawn, so these are kept individually (no aggregation).
    create table(:map_spawns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      # "pmc" | "boss" (the only categories we surface as markers).
      add :spawn_type, :string, null: false
      add :zone_name, :string

      add :pos_x, :float
      add :pos_y, :float
      add :pos_z, :float

      timestamps()
    end

    create index(:map_spawns, [:map_id])

    # Hidden caches (buried-barrel / ground caches) — the "stash" marker
    # layer. We deliberately store only the cache containers, not every
    # loose-loot container, to keep the table and the map readable.
    create table(:map_loot_containers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string
      add :normalized_name, :string

      add :pos_x, :float
      add :pos_y, :float
      add :pos_z, :float

      timestamps()
    end

    create index(:map_loot_containers, [:map_id])
  end
end
