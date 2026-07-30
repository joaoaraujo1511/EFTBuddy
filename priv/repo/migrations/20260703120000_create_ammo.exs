defmodule EftBuddy.Repo.Migrations.CreateAmmo do
  @moduledoc """
  Create the `ammo` table: one row per ammunition round, carrying the
  ballistics stats from the tarkov.dev JSON API's per-item
  `properties` fragment (`propertiesType == "ItemPropertiesAmmo"`).

  Rounds are already `items` rows (category "Ammo"), so each ammo row
  links back to its item via `item_id` — that's where the display name,
  icon and availability (trader/flea/barter/craft) are read from, so we
  never duplicate them here. `item_id` is nullable + `nilify_all` on
  delete: if the item ever drops out of the items snapshot, the ammo row
  survives (with a null link) rather than cascading away, and the next
  `EftBuddy.Ammo.Sync` run re-resolves it.

  Every ballistics column is `NOT NULL`: the JSON API returns all of
  these fields on every one of the ~195 rounds (verified across bullets,
  buckshot, grenade-launcher rounds and flares), and `EftBuddy.Ammo.Sync`
  coerces/guards the payload so a partial upstream response never tries
  to write a null here.
  """

  use Ecto.Migration

  def change do
    create table(:ammo, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # Stable tarkov.dev item id — the upsert conflict target, mirroring
      # every other synced table.
      add(:external_id, :string, null: false)

      # Link to the underlying item row (name / icon / prices / crafts).
      add(:item_id, references(:items, type: :binary_id, on_delete: :nilify_all))

      # Raw tarkov.dev caliber enum (e.g. "Caliber556x45NATO"); mapped to a
      # display label + group order by `EftBuddy.Ammo.Caliber` at render.
      add(:caliber, :string, null: false)

      # "bullet" | "buckshot" | "grenade" | "flashbang".
      add(:ammo_type, :string, null: false)

      # Core ballistics.
      add(:damage, :integer, null: false)
      add(:penetration_power, :integer, null: false)
      add(:penetration_chance, :float, null: false)
      add(:armor_damage, :integer, null: false)
      add(:ricochet_chance, :float, null: false)

      # Handling modifiers (fractions; rendered as signed %).
      add(:accuracy_modifier, :float, null: false)
      add(:recoil_modifier, :float, null: false)

      # Muzzle velocity in m/s (the item-level `velocity` is null; this
      # comes from `properties.initialSpeed`).
      add(:initial_speed, :float, null: false)

      # Pellets per shot (1 for everything except buckshot). Lets the UI
      # qualify buckshot damage as "×N".
      add(:projectile_count, :integer, null: false)

      # Bleed modifiers (fractions; rendered as signed %).
      add(:light_bleed_modifier, :float, null: false)
      add(:heavy_bleed_modifier, :float, null: false)

      # Max stack size on the flea / in inventory.
      add(:stack_max_size, :integer, null: false)

      # Tracer flag + colour token.
      add(:tracer, :boolean, null: false, default: false)
      add(:tracer_color, :string, null: false)

      timestamps()
    end

    # Upsert conflict target (one ammo row per tarkov.dev id).
    create(unique_index(:ammo, [:external_id]))

    # Each item is at most one ammo round; also speeds the item join.
    # Nullable unique is fine on Postgres (multiple NULLs allowed), which
    # matches the `nilify_all` orphan case.
    create(unique_index(:ammo, [:item_id]))

    # The Ballistics page groups + filters by caliber.
    create(index(:ammo, [:caliber]))
  end
end
