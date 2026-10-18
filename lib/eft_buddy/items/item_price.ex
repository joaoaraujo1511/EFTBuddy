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

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "item_prices" do
    field :game_mode, :string, default: "regular"

    field :base_price, :integer
    field :last_low_price, :integer
    field :avg_24h_price, :integer
    field :low_24h_price, :integer
    field :high_24h_price, :integer

    # tarkov.dev's own 48-hour flea price change, in percent. The price
    # history behind the sparkline is in `item_price_points`.
    field :change_last_48h_percent, :float

    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end
end
