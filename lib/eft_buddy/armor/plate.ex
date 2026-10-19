defmodule EftBuddy.Armor.Plate do
  @moduledoc """
  A single ballistic armor plate and its stats, synced from the
  tarkov.dev JSON API's per-item `properties` fragment (the "Armor Plate"
  category) by `EftBuddy.Armor.Sync`.

  The display name, icon and price are **not** stored here — they're read
  through the `:item` association, since every plate is already an `items`
  row. This schema carries only the plate-specific armor stats.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "armor_plates" do
    field :external_id, :string

    field :class, :integer
    field :durability, :integer
    # Material token (Ceramic / ArmoredSteel / UHMWPE / Combined / Titan /
    # Aluminium); maps to destructibility + a label via `Armor.Material`.
    field :material, :string
    # "Heavy" | "Light".
    field :armor_type, :string
    # Fraction of blocked damage bled through (0-1).
    field :blunt_throughput, :float
    # Movement / handling penalties (negative fractions).
    field :speed_penalty, :float
    field :turn_penalty, :float
    field :ergo_penalty, :float
    field :repair_cost, :integer

    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end
end
