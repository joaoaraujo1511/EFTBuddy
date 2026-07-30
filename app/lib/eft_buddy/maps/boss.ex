defmodule EftBuddy.Maps.Boss do
  @moduledoc """
  A boss spawn *entry* on a map (tarkov.dev `BossSpawn`).

  One row per entry the API returns, **not** one per (map, boss). The API
  models a boss's spawns as a list of entries, each with its own chance,
  trigger, timer and zones — Reserve's raiders have four (0.4 untriggered,
  0.3 on a `Switch`, 0.3 on `autoId_00000_D2_LEVER`, 0.3 at t=3), and The Lab's
  have sixteen. Collapsing them to one row per boss discarded all of that and
  reported a chance that was only true for the first zone.

  Cards are grouped back together on the read side by boss identity
  (`{normalized_name, name}`, not `external_id` — three distinct mob ids share
  the display name "AF" on Terminal), so a boss still shows once with its
  entries listed beneath it.

  `variant_id` ties the entry to the raid variant it belongs to, which is how
  Factory shows Tagilla at 50% (day) and 75% (night) instead of just the first.

  `spawn_locations` and `escorts` are kept as JSONB render-only blobs.

  `spawn_key` is the raw zone key (e.g. `"ZoneDormitory"`) the marker builder
  joins against `EftBuddy.Maps.Spawn`'s `zone_name` to decide which physical
  spawn points belong to this boss; `name` is its translated display form
  (`"Dorms"`) and only ever reaches the card's zone chips. `positions` is
  retained for the card, not for pin placement.

      spawn_locations :: [%{"spawn_key" => String.t(),
                            "name" => String.t(), "chance" => float(),
                            "positions" => [%{"x" => float(),
                                              "y" => float(),
                                              "z" => float()}]}]
      escorts         :: [%{"name" => String.t(),
                            "normalized_name" => String.t(),
                            "image_portrait_link" => String.t() | nil,
                            "amount" => [%{"count" => integer(),
                                           "chance" => float()}]}]
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_bosses" do
    belongs_to :map, EftBuddy.Maps.Map
    belongs_to :variant, EftBuddy.Maps.Variant

    field :external_id, :string
    field :name, :string
    field :normalized_name, :string
    field :image_portrait_link, :string

    field :spawn_chance, :float
    field :spawn_trigger, :string
    field :spawn_time, :integer
    field :spawn_time_random, :boolean

    field :spawn_locations, {:array, :map}, default: []
    field :escorts, {:array, :map}, default: []

    # The API's ordering within a map, so "first appearance" grouping is stable.
    field :position, :integer, default: 0

    timestamps()
  end

  # NOTE: the sync writes through `insert_all`, not this changeset.
  def changeset(boss, attrs) do
    boss
    |> cast(attrs, [
      :map_id,
      :variant_id,
      :external_id,
      :name,
      :normalized_name,
      :image_portrait_link,
      :spawn_chance,
      :spawn_trigger,
      :spawn_time,
      :spawn_time_random,
      :spawn_locations,
      :escorts
    ])
    |> validate_required([:map_id, :external_id, :name])
    |> foreign_key_constraint(:map_id)
    |> foreign_key_constraint(:variant_id)
  end
end
