defmodule EftBuddy.Repo.Migrations.CreateArmorPlates do
  @moduledoc """
  Create the `armor_plates` table: one row per ballistic armor plate,
  from the tarkov.dev JSON API's per-item `properties` fragment
  (`propertiesType == "ItemPropertiesArmorAttachment"` with a real
  `armorType`, i.e. the tarkov.dev "Armor Plate" category — the 38 body
  plates, excluding the face-shields / visors / ear covers).

  Plates are already `items` rows, so each plate links back to its item
  via `item_id` (nullable + `nilify_all`, same as `ammo`) for the display
  name, icon and price — we only store the plate-specific ballistics here.

  Every stat column is `NOT NULL`: the JSON API returns all of them on
  every plate, and `EftBuddy.Armor.Sync` coerces the payload so a partial
  upstream response never writes a null.
  """

  use Ecto.Migration

  def change do
    create table(:armor_plates, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:external_id, :string, null: false)
      add(:item_id, references(:items, type: :binary_id, on_delete: :nilify_all))

      # Protection class (1-6).
      add(:class, :integer, null: false)
      # Armor hit points.
      add(:durability, :integer, null: false)
      # Material token (Ceramic / ArmoredSteel / UHMWPE / …); maps to a
      # destructibility factor via `EftBuddy.Armor.Material`.
      add(:material, :string, null: false)
      # "Heavy" | "Light".
      add(:armor_type, :string, null: false)
      # Fraction of blocked damage that still bleeds through (0-1).
      add(:blunt_throughput, :float, null: false)
      # Movement / handling penalties (negative fractions).
      add(:speed_penalty, :float, null: false)
      add(:turn_penalty, :float, null: false)
      add(:ergo_penalty, :float, null: false)
      # Base repair cost (roubles per durability point).
      add(:repair_cost, :integer, null: false)

      timestamps()
    end

    create(unique_index(:armor_plates, [:external_id]))
    create(unique_index(:armor_plates, [:item_id]))
    create(index(:armor_plates, [:class]))
  end
end
