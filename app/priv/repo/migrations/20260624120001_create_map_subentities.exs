defmodule EftBuddy.Repo.Migrations.CreateMapSubentities do
  use Ecto.Migration

  @moduledoc """
  Child tables for the Maps feature, all owned by a parent `maps` row
  (`on_delete: :delete_all`, so a map disappearing from the tarkov.dev
  snapshot cascades its sub-entities away).

  Cross-domain references — a lock/access-key/extract that points at an
  `items` row, and a transit that points at another `maps` row — use
  `on_delete: :nilify_all`. We never want an item re-sync (which can
  briefly delete + reinsert rows) to cascade-delete map data; the FK
  just goes null and the next Maps.Sync re-resolves it. This mirrors how
  `tasks.map_id` / `tasks.trader_id` are wired.

  Coordinate clouds (`lootLoose`, every position's x/y/z) are
  intentionally not stored — there's no in-app map renderer to use them,
  so we keep the linkable / countable facts (names, factions, keys,
  spawn chances) and aggregate the rest.
  """

  def change do
    # ── Bosses ───────────────────────────────────────────
    create table(:map_bosses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      # `MobInfo.id` — the boss's global id (stable across maps).
      add :external_id, :string, null: false
      add :name, :string, null: false
      add :normalized_name, :string
      add :image_portrait_link, :string

      add :spawn_chance, :float
      add :spawn_trigger, :string
      add :spawn_time, :integer
      add :spawn_time_random, :boolean

      # `spawnLocations` [{name, chance}] and `escorts`
      # [{name, normalized_name, amount: [{count, chance}]}] — small,
      # render-only structures kept as JSONB arrays rather than two more
      # tables. Default to an empty JSON array (matches the
      # `{:array, :map}` schema field).
      add :spawn_locations, {:array, :map}, null: false, default: []
      add :escorts, {:array, :map}, null: false, default: []

      timestamps()
    end

    create index(:map_bosses, [:map_id])
    create unique_index(:map_bosses, [:map_id, :external_id])

    # ── Extracts ─────────────────────────────────────────
    create table(:map_extracts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :external_id, :string, null: false
      add :name, :string, null: false
      # "pmc" | "scav" | "shared"
      add :faction, :string

      # Item-gated extracts (e.g. hand over a LEDX). Nullable FK into
      # items so an item re-sync can't cascade-delete the extract.
      add :transfer_item_id,
          references(:items, type: :binary_id, on_delete: :nilify_all)

      add :transfer_item_count, :float

      timestamps()
    end

    create index(:map_extracts, [:map_id])
    create index(:map_extracts, [:transfer_item_id])
    create unique_index(:map_extracts, [:map_id, :external_id])

    # ── Transits (map-to-map links) ──────────────────────
    create table(:map_transits, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :external_id, :string, null: false
      add :description, :string
      add :conditions, :string

      # Destination map. Resolved within the same sync pass; nullable so
      # an as-yet-unknown destination doesn't drop the transit row.
      add :destination_map_id,
          references(:maps, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create index(:map_transits, [:map_id])
    create index(:map_transits, [:destination_map_id])
    create unique_index(:map_transits, [:map_id, :external_id])

    # ── Locks / keyed doors ──────────────────────────────
    create table(:map_locks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      # "door" | "trunk" | "inventory" | … (the API's free-text lockType)
      add :lock_type, :string
      add :needs_power, :boolean

      add :key_item_id,
          references(:items, type: :binary_id, on_delete: :nilify_all)

      # The API lists one lock entry per physical door/position. Without
      # a map renderer the positions are noise, so we collapse identical
      # (lock_type, key, needs_power) locks into one row + a count.
      add :count, :integer, null: false, default: 1

      timestamps()
    end

    create index(:map_locks, [:map_id])
    create index(:map_locks, [:key_item_id])

    # ── Hazards (deduped + counted) ──────────────────────
    create table(:map_hazards, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :hazard_type, :string
      add :name, :string
      # Number of positions of this hazard on the map (the API lists one
      # entry per position; we collapse to (type, name) + a count).
      add :count, :integer, null: false, default: 1

      timestamps()
    end

    create index(:map_hazards, [:map_id])
    create unique_index(:map_hazards, [:map_id, :hazard_type, :name])

    # ── Access keys (map ↔ item join) ────────────────────
    create table(:map_access_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :item_id,
          references(:items, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps()
    end

    create index(:map_access_keys, [:map_id])
    create index(:map_access_keys, [:item_id])
    create unique_index(:map_access_keys, [:map_id, :item_id])
  end
end
