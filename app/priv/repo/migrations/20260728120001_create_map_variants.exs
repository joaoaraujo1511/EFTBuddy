defmodule EftBuddy.Repo.Migrations.CreateMapVariants do
  use Ecto.Migration

  @moduledoc """
  Adds playable variants of a location (Factory day / night) as first-class
  rows, replacing the old `@merge_into` trick that folded a variant's bosses
  into its parent and tagged them with a synthesized "Night only" string.

  Every map gets one `base: true` variant so the read side is uniform; Factory
  additionally gets a `night` row carrying its own raid duration, player count
  and boss entries.

  Also drops the `(map_id, external_id)` unique index on `map_bosses`: a boss
  now gets one row per API spawn *entry*, not one per map. Collapsing them was
  losing real data — The Lab's 16 raider entries (4 chances, a Switch trigger,
  7 spawn times) became a single "Raider 60%" row.
  """

  def up do
    create table(:map_variants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :map_id, references(:maps, type: :binary_id, on_delete: :delete_all), null: false

      # The variant's own API map id / slug (e.g. "night-factory").
      add :external_id, :string
      add :normalized_name, :string, null: false
      add :name, :string
      add :name_id, :string
      # Short UI chip label: "Day" | "Night".
      add :label, :string
      add :base, :boolean, null: false, default: false
      # "base" | "night" — why this variant differs, so the UI derives the
      # badge instead of trusting a hardcoded string.
      add :kind, :string, null: false, default: "base"

      add :raid_duration, :integer
      add :players, :string
      add :min_player_level, :integer
      add :max_player_level, :integer
      add :description, :text
      add :enemies, {:array, :string}, default: []

      timestamps()
    end

    create index(:map_variants, [:map_id])
    create unique_index(:map_variants, [:map_id, :normalized_name])

    alter table(:map_bosses) do
      add :variant_id, references(:map_variants, type: :binary_id, on_delete: :delete_all)
    end

    create index(:map_bosses, [:variant_id])

    # One row per spawn entry now, so (map_id, external_id) is no longer unique.
    drop unique_index(:map_bosses, [:map_id, :external_id])
    create index(:map_bosses, [:map_id, :external_id])
  end

  def down do
    drop index(:map_bosses, [:map_id, :external_id])
    create unique_index(:map_bosses, [:map_id, :external_id])

    drop index(:map_bosses, [:variant_id])

    alter table(:map_bosses) do
      remove :variant_id
    end

    drop table(:map_variants)
  end
end
