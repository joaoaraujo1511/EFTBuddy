defmodule EftBuddy.Ammo.Round do
  @moduledoc """
  A single ammunition round and its ballistics, synced from the
  tarkov.dev JSON API's per-item `properties` fragment
  (`propertiesType == "ItemPropertiesAmmo"`) by `EftBuddy.Ammo.Sync`.

  The display name, icon and availability (trader / flea / barter /
  craft) are **not** stored here — they're read through the `:item`
  association, since every round is already an `items` row. This schema
  carries only the ballistics the Items table doesn't have.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ammo" do
    field :external_id, :string

    # Raw tarkov.dev caliber enum ("Caliber556x45NATO"); mapped to a
    # display label + group order by `EftBuddy.Ammo.Caliber`.
    field :caliber, :string
    # "bullet" | "buckshot" | "grenade" | "flashbang".
    field :ammo_type, :string

    # Core ballistics.
    field :damage, :integer
    field :penetration_power, :integer
    field :penetration_chance, :float
    field :armor_damage, :integer
    field :ricochet_chance, :float

    # Handling modifiers (fractions; rendered signed %).
    field :accuracy_modifier, :float
    field :recoil_modifier, :float

    # Muzzle velocity, m/s (from properties.initialSpeed).
    field :initial_speed, :float

    # Pellets per shot (>1 only for buckshot).
    field :projectile_count, :integer

    # Bleed modifiers (fractions; rendered signed %).
    field :light_bleed_modifier, :float
    field :heavy_bleed_modifier, :float

    field :stack_max_size, :integer
    field :tracer, :boolean, default: false
    field :tracer_color, :string

    # Virtual overlay: where this round can be obtained, derived at query
    # time by `EftBuddy.Ammo.list_rounds/0` from the linked item's
    # buy_for / barter / craft rows (never stored). A list of the source
    # tokens `"trader"`, `"flea"`, `"barter"`, `"craft"`.
    field :sources, {:array, :string}, virtual: true, default: []

    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end

  @doc """
  Changeset for creating/updating an ammo round from API data.
  """
  def changeset(round, attrs) do
    round
    |> cast(attrs, [
      :external_id,
      :item_id,
      :caliber,
      :ammo_type,
      :damage,
      :penetration_power,
      :penetration_chance,
      :armor_damage,
      :ricochet_chance,
      :accuracy_modifier,
      :recoil_modifier,
      :initial_speed,
      :projectile_count,
      :light_bleed_modifier,
      :heavy_bleed_modifier,
      :stack_max_size,
      :tracer,
      :tracer_color
    ])
    |> validate_required([:external_id, :caliber, :ammo_type, :damage, :penetration_power])
    |> unique_constraint(:external_id)
    |> unique_constraint(:item_id)
    |> foreign_key_constraint(:item_id)
  end
end
