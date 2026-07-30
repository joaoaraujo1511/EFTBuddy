defmodule EftBuddy.Maps.Variant do
  @moduledoc """
  A playable variant of a location — Factory's day and night raids are the same
  physical map with different raid parameters and different bosses.

  Every map has exactly one `base: true` variant so the read side never has to
  special-case "map with variants" vs "map without". Factory additionally has a
  `kind: "night"` row.

  This replaces the old `EftBuddy.Maps.Sync` `@merge_into` behaviour, which
  copied a variant's bosses onto the parent and stamped them with a literal
  `"Night only"` string. That conflated three different things — where the data
  came from, why the variant differs, and how to label it — and got Ground Zero
  wrong as a result (its `ground-zero-21` sibling is a *level bracket*, not a
  night map).

  `kind` is the machine-readable reason for the difference, so the UI derives
  its badge rather than trusting prose:

    * `"base"`  — the default raid
    * `"night"` — night-only raid (Factory)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_variants" do
    belongs_to :map, EftBuddy.Maps.Map

    field :external_id, :string
    field :normalized_name, :string
    field :name, :string
    field :name_id, :string
    field :label, :string
    field :base, :boolean, default: false
    field :kind, :string, default: "base"

    field :raid_duration, :integer
    field :players, :string
    field :min_player_level, :integer
    field :max_player_level, :integer
    field :description, :string
    field :enemies, {:array, :string}, default: []

    has_many :bosses, EftBuddy.Maps.Boss, foreign_key: :variant_id

    timestamps()
  end

  def changeset(variant, attrs) do
    variant
    |> cast(attrs, [
      :map_id,
      :external_id,
      :normalized_name,
      :name,
      :name_id,
      :label,
      :base,
      :kind,
      :raid_duration,
      :players,
      :min_player_level,
      :max_player_level,
      :description,
      :enemies
    ])
    |> validate_required([:map_id, :normalized_name])
    |> validate_inclusion(:kind, ~w(base night))
    |> unique_constraint([:map_id, :normalized_name])
    |> foreign_key_constraint(:map_id)
  end
end
