defmodule EftBuddy.Fixtures do
  @moduledoc """
  Insert helpers for tests. Each builds a valid row with sensible
  defaults and inserts it via `Repo.insert!/1`. Pass a map (or keyword
  list) of overrides to customize any field, including the `*_id`
  foreign keys.

  Defaults use `System.unique_integer/1` for the unique columns
  (`external_id`, `normalized_name`, …) so callers can create many
  rows without worrying about collisions.
  """

  alias EftBuddy.Repo

  alias EftBuddy.Hideout.{ItemRequirement, Station, StationLevel, Trader}

  alias EftBuddy.Items.{
    Barter,
    BarterRequiredItem,
    BarterRewardItem,
    Category,
    Craft,
    CraftRequiredItem,
    CraftRewardItem,
    Item,
    ItemPrice,
    SellFor,
    Vendor
  }

  alias EftBuddy.Maps.{AccessKey, Boss, Spawn, Variant}
  alias EftBuddy.Maps.Map, as: GameMap

  alias EftBuddy.Tasks.{ItemReward, Objective, OfferUnlock, Task, TaskRequirement}

  defp uid, do: System.unique_integer([:positive])

  defp insert(schema, defaults, attrs) do
    Repo.insert!(struct(schema, Map.merge(defaults, Map.new(attrs))))
  end

  def category(attrs \\ %{}) do
    n = uid()

    insert(
      Category,
      %{
        external_id: "cat-#{n}",
        name: "Category #{n}",
        normalized_name: "category-#{n}",
        min_level_for_flea_market: 1
      },
      attrs
    )
  end

  def item(attrs \\ %{}) do
    n = uid()
    attrs = Map.new(attrs)

    item =
      insert(
        Item,
        %{
          external_id: "item-#{n}",
          name: "Item #{n}",
          short_name: "I#{n}",
          normalized_name: "item-#{n}",
          base_price: 1_000,
          is_quest_item: false
        },
        attrs
      )

    # Mirror the item's price fields into a regular `item_prices` row so
    # the mode-aware flea/items queries (which read `item_prices`, not
    # the `items` columns) see them. Tests that need PVE prices can call
    # `item_price/1` explicitly with `game_mode: "pve"`. Quest items have
    # no economy, so they get no price row.
    unless item.is_quest_item do
      price_attrs =
        Map.take(attrs, [
          :base_price,
          :last_low_price,
          :avg_24h_price,
          :low_24h_price,
          :high_24h_price
        ])

      item_price(Map.merge(%{item_id: item.id, base_price: item.base_price}, price_attrs))
    end

    item
  end

  @doc """
  Insert a per-mode price row for an item. Defaults to the `regular`
  (PVP) mode; pass `game_mode: "pve"` for a PVE price. Requires
  `item_id`.
  """
  def item_price(attrs \\ %{}) do
    insert(ItemPrice, %{game_mode: "regular"}, attrs)
  end

  def vendor(attrs \\ %{}) do
    n = uid()
    insert(Vendor, %{name: "Vendor #{n}", normalized_name: "vendor-#{n}"}, attrs)
  end

  @doc """
  Insert a `sell_for` row (a vendor sell price). Defaults to the
  `regular` mode; requires `item_id` and `vendor_id`.
  """
  def sell_for(attrs \\ %{}) do
    insert(SellFor, %{price: 100, price_rub: 100, currency: "RUB", game_mode: "regular"}, attrs)
  end

  def trader(attrs \\ %{}) do
    n = uid()
    insert(Trader, %{name: "Trader #{n}", normalized_name: "trader-#{n}"}, attrs)
  end

  def station(attrs \\ %{}) do
    n = uid()
    insert(Station, %{name: "Station #{n}", normalized_name: "station-#{n}"}, attrs)
  end

  def station_level(attrs \\ %{}) do
    insert(StationLevel, %{level: 1}, attrs)
  end

  def item_requirement(attrs \\ %{}) do
    insert(ItemRequirement, %{quantity: 1}, attrs)
  end

  def barter(attrs \\ %{}) do
    n = uid()
    insert(Barter, %{external_id: "barter-#{n}", level: 1, buy_limit: 0}, attrs)
  end

  def barter_required(attrs \\ %{}) do
    insert(BarterRequiredItem, %{count: 1, quantity: 1, attributes: %{}}, attrs)
  end

  def barter_reward(attrs \\ %{}) do
    insert(BarterRewardItem, %{count: 1, quantity: 1}, attrs)
  end

  def craft(attrs \\ %{}) do
    n = uid()
    insert(Craft, %{external_id: "craft-#{n}", duration: 3_600}, attrs)
  end

  def craft_required(attrs \\ %{}) do
    insert(CraftRequiredItem, %{count: 1, quantity: 1, attributes: %{}}, attrs)
  end

  def craft_reward(attrs \\ %{}) do
    insert(CraftRewardItem, %{count: 1, quantity: 1}, attrs)
  end

  def task(attrs \\ %{}) do
    n = uid()

    insert(
      Task,
      %{
        external_id: "task-#{n}",
        name: "Task #{n}",
        normalized_name: "task-#{n}",
        kappa_required: false
      },
      attrs
    )
  end

  def objective(attrs \\ %{}) do
    n = uid()

    insert(
      Objective,
      %{
        external_id: "obj-#{n}",
        type: "giveItem",
        description: "Objective #{n}",
        optional: false,
        payload: %{},
        position: 0
      },
      attrs
    )
  end

  def task_requirement(attrs \\ %{}) do
    insert(TaskRequirement, %{status: ["complete"]}, attrs)
  end

  def item_reward(attrs \\ %{}) do
    insert(ItemReward, %{quantity: 1, reward_phase: :finish}, attrs)
  end

  def offer_unlock(attrs \\ %{}) do
    insert(OfferUnlock, %{level: 1, reward_phase: :finish}, attrs)
  end

  # ── Maps ───────────────────────────────────────────────

  @doc """
  A map row. Defaults to an SVG-projection map with the projection maths
  populated, since `EftBuddy.Maps.visible?/1` and
  `EftBuddy.Maps.Assets.interactive?/1` both key off those.
  """
  def game_map(attrs \\ %{}) do
    n = uid()

    insert(
      GameMap,
      %{
        external_id: "map-#{n}",
        name: "Map #{n}",
        normalized_name: "map-#{n}",
        raid_duration: 40,
        players: "10-12",
        enemies: [],
        projection: "svg",
        transform: [0.2, 0.0, 0.2, 0.0],
        coordinate_rotation: 180.0,
        bounds: [[100.0, -100.0], [-100.0, 100.0]],
        min_zoom: 1,
        max_zoom: 6,
        layers: [],
        labels: [],
        image_variants: %{}
      },
      attrs
    )
  end

  @doc "A raid variant of a map (base unless overridden)."
  def map_variant(attrs \\ %{}) do
    n = uid()

    insert(
      Variant,
      %{
        external_id: "variant-#{n}",
        normalized_name: "variant-#{n}",
        name: "Variant #{n}",
        base: true,
        kind: "base",
        raid_duration: 40,
        players: "10-12",
        enemies: []
      },
      attrs
    )
  end

  @doc "A single boss spawn *entry* on a map."
  def map_boss(attrs \\ %{}) do
    n = uid()

    insert(
      Boss,
      %{
        external_id: "boss-#{n}",
        name: "Boss #{n}",
        normalized_name: "boss-#{n}",
        spawn_chance: 0.5,
        spawn_time: -1,
        spawn_locations: [],
        escorts: [],
        # The sync numbers these per map; pass an explicit `position` when a
        # test asserts on card / chip ordering.
        position: 0
      },
      attrs
    )
  end

  @doc "An access key gating entry to a map."
  def map_access_key(attrs \\ %{}) do
    insert(AccessKey, %{}, attrs)
  end

  @doc """
  A single physical spawn point. Defaults to a boss-category, bot+scav point —
  the shape the marker builder has to decide about (boss pin or scav pin,
  depending on whether any boss claims `zone_name`).
  """
  def map_spawn(attrs \\ %{}) do
    insert(
      Spawn,
      %{
        spawn_type: "boss",
        zone_name: "ZoneDormitory",
        sides: ["scav"],
        categories: ["bot", "boss"],
        pos_x: 0.0,
        pos_y: 0.0,
        pos_z: 0.0
      },
      attrs
    )
  end
end
