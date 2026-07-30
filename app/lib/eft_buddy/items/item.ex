defmodule EftBuddy.Items.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items" do
    field :external_id, :string
    field :name, :string
    field :short_name, :string
    field :normalized_name, :string
    field :description, :string
    field :base_price, :integer
    field :last_low_price, :integer
    field :avg_24h_price, :integer
    field :low_24h_price, :integer
    field :high_24h_price, :integer
    field :wiki_link, :string
    field :link, :string
    field :icon_link, :string
    field :grid_image_link, :string
    field :base_image_link, :string
    field :inspect_image_link, :string
    field :image_512px_link, :string
    field :image_8x_link, :string
    # Inventory tier color token from the tarkov.dev `Item.backgroundColor`
    # field — one of the canonical EFT palette tokens (e.g. "blue", "violet",
    # "yellow"). Mapped to a CSS hex value by
    # `EftBuddy.Items.BackgroundColor` at render time so the LiveView can
    # paint a tile background behind the high-res `image_512px_link` and
    # keep the tier-color cue that the small `icon_link` PNG bakes in.
    field :background_color, :string
    # Minimum PMC level required to list/trade this item on the flea
    # market, from tarkov.dev `Item.minLevelForFlea` (mirrors the
    # category-level value but resolved per item). NULL when the API
    # doesn't specify one, in which case the flea page falls back to the
    # category value and then the global flea unlock level.
    field :min_level_for_flea, :integer
    # True for the Tarkov.dev `QuestItem` rows we sync into this
    # same table — Golden Zibbo lighter, Cult medallion, etc.
    # These are quest-exclusive and have NULL price / category /
    # background_color (they don't trade and have no tier color).
    # We carry them here rather than in a separate `quest_items`
    # table so the existing items page search / detail page work
    # unchanged: a click on a quest-item tile from the Tasks page
    # opens /items?q=<name> and finds the row.
    field :is_quest_item, :boolean, default: false

    has_many :sell_for, EftBuddy.Items.SellFor, foreign_key: :item_id
    has_many :buy_for, EftBuddy.Items.BuyFor, foreign_key: :item_id

    # Per-mode economy snapshot (one row per game mode). The columns
    # above (last_low_price, avg/low/high_24h_price, base_price) are the
    # `regular` mirror kept for backward compat and the periodic price
    # refresh; mode-aware reads use these rows.
    has_many :prices, EftBuddy.Items.ItemPrice, foreign_key: :item_id

    # Virtual overlay for the active game mode's flea price history,
    # filled in by `EftBuddy.Items.select_merge_mode_prices/1` from the
    # joined `item_prices` row (same overlay pattern as the price columns
    # above). A JSON array of `%{"price" => int, "timestamp" => int_ms}`
    # points; `nil` when the item has no history. Lives on the struct
    # (not the DB) so every template that renders an `%Item{}` — flea
    # card, items detail panel — can read `item.historical_prices`.
    field :historical_prices, {:array, :map}, virtual: true

    # Source-of-this-item edges. The "for" side (item is rewarded
    # *by* a recipe) is what the expanded UI panel renders under
    # "where it comes from"; the "using" side (item is consumed
    # *by* a recipe) is the inverse and lets us answer "what does
    # this item enable" if we ever want it. Both are populated by
    # `EftBuddy.Items.Sync`.
    has_many :barter_rewards, EftBuddy.Items.BarterRewardItem, foreign_key: :item_id
    has_many :barter_costs, EftBuddy.Items.BarterRequiredItem, foreign_key: :item_id
    has_many :craft_rewards, EftBuddy.Items.CraftRewardItem, foreign_key: :item_id
    has_many :craft_costs, EftBuddy.Items.CraftRequiredItem, foreign_key: :item_id

    belongs_to :category, EftBuddy.Items.Category

    # Self-referential pointer to the item this one *contains* (one
    # level deep, single-content only). Today this is populated only
    # for ammo boxes via the `properties.ammo` fragment on the
    # tarkov.dev items query — e.g. "Pack of .300 Blackout CBJ ammo"
    # gets a `contains_item_id` pointing to the ".300 Blackout CBJ"
    # round. Used by the `:barter` and `:craft` scope filters in
    # `EftBuddy.Items` to avoid listing both the box and its round
    # when they map to the same in-game barter (the API encodes some
    # ammo barters against the round id directly).
    belongs_to :contains_item, EftBuddy.Items.Item, foreign_key: :contains_item_id

    timestamps()
  end

  @doc """
  Creates a changeset for item creation from API data.

  ## Examples
      Item.changeset(%Item{}, %{
        external_id: "5ac66cb05acfc400192632fc",
        name: "AK-74",
        base_price: 50000
      })
  """
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :external_id,
      :name,
      :short_name,
      :normalized_name,
      :description,
      :base_price,
      :last_low_price,
      :avg_24h_price,
      :low_24h_price,
      :high_24h_price,
      :wiki_link,
      :link,
      :icon_link,
      :grid_image_link,
      :base_image_link,
      :inspect_image_link,
      :image_512px_link,
      :image_8x_link,
      :background_color,
      :min_level_for_flea,
      :is_quest_item,
      :category_id,
      :contains_item_id
    ])
    |> validate_required([:external_id, :name, :base_price])
    |> unique_constraint(:external_id)
  end

  @doc """
  Creates a changeset for updating existing items.
  More permissive than create changeset.
  """
  def update_changeset(item, attrs) do
    item
    |> cast(attrs, [
      :name,
      :short_name,
      :normalized_name,
      :description,
      :base_price,
      :last_low_price,
      :avg_24h_price,
      :low_24h_price,
      :high_24h_price,
      :wiki_link,
      :link,
      :icon_link,
      :grid_image_link,
      :base_image_link,
      :inspect_image_link,
      :image_512px_link,
      :image_8x_link,
      :background_color,
      :min_level_for_flea,
      :is_quest_item,
      :category_id,
      :contains_item_id
    ])
  end
end
