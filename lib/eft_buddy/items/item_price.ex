defmodule EftBuddy.Items.ItemPrice do
  @moduledoc """
  Per-mode economy snapshot for an item.

  Item entities are identical across PVP/PVE, but their prices are
  not. Since there is one `items` row per item, the two modes' prices
  live here, keyed by `(item_id, game_mode)`. Carries the volatile
  flea-market columns plus `base_price` (which itself diverges per
  mode for a few hundred items).

  Written by `EftBuddy.Items.Sync` for both `"regular"` and `"pve"`;
  read (filtered by the active mode) by the flea market and item
  detail queries in `EftBuddy.Items`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "item_prices" do
    field :game_mode, :string, default: "regular"

    field :base_price, :integer
    field :last_low_price, :integer
    field :avg_24h_price, :integer
    field :low_24h_price, :integer
    field :high_24h_price, :integer

    # Accumulated flea price history powering the sparkline / detail
    # graph. A JSON array of `%{"price" => int, "timestamp" => int_ms}`
    # points, oldest first. tarkov.dev's JSON API has no price time
    # series, so `EftBuddy.Items.Sync` builds this itself: each price
    # refresh appends the item's current `lastLowPrice` and trims to a
    # bounded window. NULL/`[]` until enough refreshes have accumulated.
    field :historical_prices, {:array, :map}

    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end

  def changeset(item_price, attrs) do
    item_price
    |> cast(attrs, [
      :game_mode,
      :base_price,
      :last_low_price,
      :avg_24h_price,
      :low_24h_price,
      :high_24h_price,
      :historical_prices,
      :item_id
    ])
    |> validate_required([:game_mode, :item_id])
    |> unique_constraint([:item_id, :game_mode],
      name: :item_prices_item_id_game_mode_index
    )
    |> foreign_key_constraint(:item_id)
  end
end
