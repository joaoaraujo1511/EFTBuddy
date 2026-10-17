defmodule EftBuddy.Items.ItemPricePoint do
  @moduledoc """
  One flea price observation for an item in a game mode, written only when the
  price changed. The sparkline draws these as a step line: a price holds until
  the next point.

  Points older than `window_ms/0` are pruned, except each item's latest one
  before the window, which is where its line starts.
  """

  use Ecto.Schema

  schema "item_price_points" do
    field :game_mode, :string
    field :observed_at, :naive_datetime
    field :price, :integer

    belongs_to :item, EftBuddy.Items.Item, type: :binary_id
  end

  @window_ms 48 * 60 * 60 * 1_000

  @doc "How much history the sparkline shows and the price tick keeps: 48 hours."
  def window_ms, do: @window_ms
end
