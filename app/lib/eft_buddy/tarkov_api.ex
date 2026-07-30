defmodule EftBuddy.TarkovApi do
  @moduledoc """
  Client + adapter for the **tarkov.dev JSON API** (https://json.tarkov.dev).

  This module replaces the previous direct GraphQL calls
  (`https://api.tarkov.dev/graphql`) that lived inside each `*.Sync`
  module. The four sync pipelines (items, tasks, maps, hideout) are
  unchanged below the fetch boundary: they still receive **the exact same
  map shape they consumed from GraphQL** (string keys, camelCase field
  names, nested `%{"id" => ...}` refs, `sellFor`/`buyFor` with a
  `vendor`, …). All the JSON↔GraphQL impedance mismatch is absorbed here
  so the heavily-tested `sanitize_*` / `upsert_*` / `cleanup_*` code keeps
  working untouched.

  ## Why an adapter, not a rewrite

  The JSON API carries the *same data* as the GraphQL API but in a
  materially different envelope:

    * **Maps, not lists.** `/items`, `/tasks`, `/hideout`, `/traders` and
      `/maps` return their primary collection as a JSON object keyed by
      id; the GraphQL API returned a list. We `Map.values/1` them.

    * **Id references, not nested objects.** Where GraphQL embedded
      `trader { id normalizedName }`, `station { normalizedName }`,
      `item { id }`, `map { id }`, the JSON API stores a bare id string
      (`"trader": "<id>"`). We resolve those against sibling endpoints
      (`/traders`, `/hideout`, `/maps`) and re-inflate the nested shape.

    * **Different field names.** Barters use `minTraderLevel` for the
      loyalty `level` and `offeredItem` (singular) for `rewardItems`;
      crafts use `productItem`; hideout/objective item requirements use
      `count` where GraphQL used `quantity`; items expose
      `sellToTrader`/`buyFromTrader` instead of `sellFor`/`buyFor`.

    * **Flea-market prices are split out.** GraphQL folded a synthetic
      "Flea Market" vendor into `sellFor`/`buyFor`; the JSON API keeps
      `sellToTrader`/`buyFromTrader` trader-only and exposes the flea
      numbers as the `lastLowPrice` / `avg24hPrice` columns. We
      reconstruct the flea vendor rows the app expects (sell price =
      `lastLowPrice`, buy price = `avg24hPrice`, matching the GraphQL
      resolver's own logic).

    * **Translations are deferred.** Every translatable field
      (`name`, `shortName`, `description`, category/skill/boss names, …)
      comes back as a *placeholder key* like `"<id> Name"`; the real
      localized string lives in a sibling document
      `/{gameMode}/{endpoint}_en` shaped `{"data": {key => value}}`. We
      fetch the English locale alongside each translatable endpoint and
      substitute (`translate/2`). A translatable fetch fails outright if
      its locale can't be loaded, so the sync never writes placeholder
      text or prunes good rows against a half-resolved snapshot.

  ## Game mode

  The `gameMode` path segment is one of `EftBuddy.GameMode.all/0`
  (`"regular"` / `"pve"`) — the same controlled constants the GraphQL
  `gameMode:` argument used, so they drop straight into the path.

  ## Return contract

  Every public fetcher returns `{:ok, [map]}` (a list of GraphQL-shaped
  maps) or `{:error, reason}`, mirroring the old `fetch_*` helpers, so
  the call sites in the sync modules only had to swap which function they
  call.
  """

  require Logger

  alias EftBuddy.Sync.Helpers

  @http_timeout 60_000
  @flea_market_name "Flea Market"
  @flea_market_slug "flea-market"

  # ── Configuration ──────────────────────────────────────

  @doc """
  Base URL of the JSON API, e.g. `"https://json.tarkov.dev"` (no trailing
  slash). Read from `:eft_buddy, :tarkov_json_api_url` so a local mirror
  can be substituted for tests / offline work.
  """
  def base_url do
    Application.get_env(:eft_buddy, :tarkov_json_api_url, "https://json.tarkov.dev")
  end

  # ── Public fetchers (return {:ok, [graphql-shaped map]}) ─

  @doc """
  Items for `game_mode` (default `"regular"`), shaped exactly like the
  old GraphQL `items` list: `category`, `containsItems`, `sellFor`,
  `buyFor` (with reconstructed flea-market vendor rows) and every
  image/price/flag field. Names/descriptions/category names are
  translated to English.

  Used both for the entity sync (regular) and the per-mode price+vendor
  pass (regular and pve).
  """
  def items(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/items"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/items_en"),
         {:ok, traders} <- traders_index(game_mode) do
      categories = get_in(body, ["data", "itemCategories"]) || %{}
      items = (get_in(body, ["data", "items"]) || %{}) |> Map.values()

      {:ok, Enum.map(items, &item_to_graphql(&1, categories, traders, locale))}
    end
  end

  @doc """
  Lightweight flea-price snapshot for `game_mode` — only the volatile
  flea columns the frequent price-refresh tick reads (`id`, `basePrice`,
  `avg24hPrice`, `low24hPrice`, `high24hPrice`, `lastLowPrice`). No
  translation, no traders, no category resolution — those are wasted
  work on the 15-minute cadence.
  """
  def flea_prices(game_mode) do
    with {:ok, body} <- get_json("/#{game_mode}/items") do
      items = (get_in(body, ["data", "items"]) || %{}) |> Map.values()

      rows =
        Enum.map(items, fn item ->
          Map.take(item, [
            "id",
            "basePrice",
            "avg24hPrice",
            "low24hPrice",
            "high24hPrice",
            "lastLowPrice"
          ])
        end)

      {:ok, rows}
    end
  end

  @doc """
  The global flea-market configuration object for `game_mode` from
  `data.fleaMarket` in the items document — most importantly
  `minPlayerLevel`, the PMC level at which the flea market *itself*
  unlocks (15 today). This is distinct from each item's own
  `minLevelForFlea`: `fleaMarket.minPlayerLevel` is the global gate
  (a hard floor) while `Item.minLevelForFlea` is a per-item restriction
  layered on top (e.g. the Colt M4A1's 25). The effective level to trade
  an item is `max(fleaMarket.minPlayerLevel, item.minLevelForFlea)`.

  Returns `{:ok, map}` (the raw `fleaMarket` object, string keys) or
  `{:error, reason}`. Shares the items document — there's no lighter
  endpoint for it — so callers should fetch it sparingly (once per full
  sync), not on the frequent price tick.
  """
  def flea_market(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/items") do
      case get_in(body, ["data", "fleaMarket"]) do
        %{} = fm -> {:ok, fm}
        _ -> {:error, :flea_market_missing}
      end
    end
  end

  @doc """
  Ammunition rounds for `game_mode` (default `"regular"`) — every item
  whose `properties.propertiesType == "ItemPropertiesAmmo"`, flattened to
  the ballistics fields `EftBuddy.Ammo.Sync` stores, plus the translated
  `name`/`shortName`, the `normalizedName`, and the item `id` (the FK
  link back to `items`).

  Ammo ballistics are static item stats — byte-identical across game
  modes — so the sync only ever calls this for the default mode; the arg
  exists for parity/testing. `name`/`shortName` come back as placeholder
  keys on the items document and are resolved against the `items_en`
  locale, exactly like `items/1`.
  """
  def ammo(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/items"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/items_en") do
      rows =
        (get_in(body, ["data", "items"]) || %{})
        |> Map.values()
        |> Enum.filter(&ammo?/1)
        |> Enum.map(&ammo_to_map(&1, locale))

      {:ok, rows}
    end
  end

  @doc """
  Ballistic armor plates for `game_mode` (default `"regular"`) — the
  tarkov.dev "Armor Plate" items (`propertiesType ==
  "ItemPropertiesArmorAttachment"` with a real `armorType`, i.e. body
  plates, not the face-shields / visors / ear covers). Flattened to the
  plate stats `EftBuddy.Armor.Sync` stores plus the item `id` (the FK link
  back to `items`, from which the name / icon / price are read).

  Plate stats are static item data (no per-mode divergence), so the sync
  only calls this for the default mode; no translation is needed since the
  name comes from the linked item.
  """
  def plates(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/items") do
      rows =
        (get_in(body, ["data", "items"]) || %{})
        |> Map.values()
        |> Enum.filter(&plate?/1)
        |> Enum.map(&plate_to_map/1)

      {:ok, rows}
    end
  end

  @doc """
  Quest-only items (Golden Zibbo, cult medallions, …). On the JSON API
  these live under the **tasks** endpoint (`data.questItems`), not a
  separate query. Shaped like the old GraphQL `questItems` list
  (`id, name, shortName, description, iconLink, gridImageLink,
  baseImageLink, image512pxLink`), translated to English.
  """
  def quest_items(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/tasks"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/tasks_en") do
      quest_items = (get_in(body, ["data", "questItems"]) || %{}) |> Map.values()

      rows =
        Enum.map(quest_items, fn qi ->
          %{
            "id" => qi["id"],
            "name" => translate(qi["name"], locale),
            "shortName" => translate(qi["shortName"], locale),
            "description" => translate(qi["description"], locale),
            "iconLink" => qi["iconLink"],
            "gridImageLink" => qi["gridImageLink"],
            "baseImageLink" => qi["baseImageLink"],
            "image512pxLink" => qi["image512pxLink"]
          }
        end)

      {:ok, rows}
    end
  end

  @doc """
  Barters for `game_mode`, shaped like the old GraphQL `barters` list:
  `id, level, buyLimit, trader{id,normalizedName}, taskUnlock{id},
  requiredItems[{item{id},count,quantity,attributes[{name,value}]}],
  rewardItems[...]`. Not a translatable endpoint.
  """
  def barters(game_mode) do
    with {:ok, body} <- get_json("/#{game_mode}/barters"),
         {:ok, traders} <- traders_index(game_mode) do
      rows = body |> data_list() |> Enum.map(&barter_to_graphql(&1, traders))
      {:ok, rows}
    end
  end

  @doc """
  Crafts for `game_mode` (default `"regular"`; crafts are byte-identical
  across modes so the app keeps a single set), shaped like the old
  GraphQL `crafts` list. Stations are resolved to
  `station{id,normalizedName}` via the hideout endpoint.
  """
  def crafts(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/crafts"),
         {:ok, stations} <- station_slug_index(game_mode) do
      rows = body |> data_list() |> Enum.map(&craft_to_graphql(&1, stations))
      {:ok, rows}
    end
  end

  @doc """
  Tasks for `game_mode`, shaped like the old GraphQL `tasks` list:
  full quest fields, inline-fragment-style objective fields, requirements
  and start/finish rewards. Traders and maps are re-inflated from their
  sibling endpoints; names and objective descriptions are translated.
  """
  def tasks(game_mode) do
    with {:ok, body} <- get_json("/#{game_mode}/tasks"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/tasks_en"),
         {:ok, traders} <- traders_index(game_mode),
         {:ok, maps} <- maps_index(game_mode) do
      tasks = (get_in(body, ["data", "tasks"]) || %{}) |> Map.values()
      {:ok, Enum.map(tasks, &task_to_graphql(&1, traders, maps, locale))}
    end
  end

  @doc """
  Maps for `game_mode` (default `"regular"`), shaped like the old GraphQL
  `maps` list: bosses (with `boss`/`escorts` re-inflated from `data.mobs`),
  extracts, transits, locks, hazards, spawns, lootContainers (re-inflated
  from `data.lootContainers`) and accessKeys. Names/descriptions/enemy and
  boss names are translated.
  """
  def maps(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/maps") do
      # Unlike the other translatable endpoints, a locale blip here degrades
      # instead of aborting: `translate/2` already falls back to the raw value,
      # which for maps means English-ish placeholders rather than nothing at
      # all — and losing every map, boss, extract and marker until the next
      # boot is far worse than a few untranslated zone names.
      locale = fetch_maps_locale(game_mode)

      data = body["data"] || %{}
      mobs = data["mobs"] || %{}
      containers = data["lootContainers"] || %{}
      weapons = data["stationaryWeapons"] || %{}
      maps = (data["maps"] || %{}) |> Map.values()
      {:ok, Enum.map(maps, &map_to_graphql(&1, mobs, containers, weapons, locale))}
    end
  end

  @doc """
  Hideout stations for `game_mode` (default `"regular"`), shaped like the
  old GraphQL `hideoutStations` list: `name, normalizedName, levels[...]`
  with the four requirement sub-lists re-inflated (stations/traders
  resolved from ids, item requirements remapped from `count` to
  `quantity`). Station names and skill names are translated.
  """
  def hideout_stations(game_mode \\ default_mode()) do
    with {:ok, body} <- get_json("/#{game_mode}/hideout"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/hideout_en"),
         {:ok, traders} <- traders_index(game_mode) do
      stations_by_id = body["data"] || %{}

      # Station-level requirements reference other stations by id; build a
      # name/slug lookup from the same payload so we can re-inflate them.
      station_refs =
        Map.new(stations_by_id, fn {id, s} ->
          {id, %{"name" => translate(s["name"], locale), "normalizedName" => s["normalizedName"]}}
        end)

      rows =
        stations_by_id
        |> Map.values()
        |> Enum.map(&station_to_graphql(&1, station_refs, traders, locale))

      {:ok, rows}
    end
  end

  # ── Cross-endpoint indexes ─────────────────────────────

  # %{trader_id => %{"name" => <english>, "normalizedName" => slug,
  #                  "imageLink" => url}}. Used to re-inflate the trader id
  # references the JSON API uses in items/barters/tasks/hideout.
  defp traders_index(game_mode) do
    with {:ok, body} <- get_json("/#{game_mode}/traders"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/traders_en") do
      index =
        Map.new(body["data"] || %{}, fn {id, t} ->
          {id,
           %{
             "name" => translate(t["name"], locale),
             "normalizedName" => t["normalizedName"],
             "imageLink" => t["imageLink"]
           }}
        end)

      {:ok, index}
    end
  end

  # %{map_id => %{"id" => id, "name" => <english>, "normalizedName" =>
  # slug}}. Used by the tasks adapter to re-inflate `task.map` and each
  # objective's `maps[]` (which the JSON API stores as bare ids).
  defp maps_index(game_mode) do
    with {:ok, body} <- get_json("/#{game_mode}/maps"),
         {:ok, locale} <- fetch_locale("/#{game_mode}/maps_en") do
      index =
        Map.new(get_in(body, ["data", "maps"]) || %{}, fn {id, m} ->
          {id,
           %{
             "id" => id,
             "name" => translate(m["name"], locale),
             "normalizedName" => m["normalizedName"]
           }}
        end)

      {:ok, index}
    end
  end

  # %{station_id => normalizedName}. Used by the crafts adapter (crafts
  # reference their station by id).
  defp station_slug_index(game_mode) do
    with {:ok, body} <- get_json("/#{game_mode}/hideout") do
      index =
        Map.new(body["data"] || %{}, fn {id, s} -> {id, s["normalizedName"]} end)

      {:ok, index}
    end
  end

  # ── Items adapter ──────────────────────────────────────

  defp item_to_graphql(item, categories, traders, locale) do
    %{
      "id" => item["id"],
      "name" => translate(item["name"], locale),
      "shortName" => translate(item["shortName"], locale),
      "normalizedName" => item["normalizedName"],
      "description" => translate(item["description"], locale),
      "basePrice" => item["basePrice"],
      "avg24hPrice" => item["avg24hPrice"],
      "low24hPrice" => item["low24hPrice"],
      "high24hPrice" => item["high24hPrice"],
      "wikiLink" => item["wikiLink"],
      "link" => item["link"],
      "iconLink" => item["iconLink"],
      "gridImageLink" => item["gridImageLink"],
      "baseImageLink" => item["baseImageLink"],
      "inspectImageLink" => item["inspectImageLink"],
      "image512pxLink" => item["image512pxLink"],
      "image8xLink" => item["image8xLink"],
      "backgroundColor" => item["backgroundColor"],
      "minLevelForFlea" => item["minLevelForFlea"],
      "lastLowPrice" => item["lastLowPrice"],
      "category" => item_category(item, categories, locale),
      "containsItems" => contains_items(item["containsItems"]),
      "sellFor" => trader_prices(item["sellToTrader"], traders) ++ flea_sell(item),
      "buyFor" => trader_prices(item["buyFromTrader"], traders) ++ flea_buy(item)
    }
  end

  # The GraphQL `Item.category` was the most-specific *item* category —
  # i.e. `categories[0]`. Its `imageLink` / `minLevelForFlea` always came
  # back null for the item category (those only exist on handbook
  # categories), so we keep them nil to match the data the DB already
  # holds. Resolves the id against `data.itemCategories`.
  defp item_category(item, categories, locale) do
    with cat_id when is_binary(cat_id) <- item["categories"] |> List.wrap() |> List.first(),
         %{} = cat <- Map.get(categories, cat_id) do
      %{
        "id" => cat["id"],
        "name" => translate(cat["name"], locale),
        "normalizedName" => cat["normalizedName"],
        "imageLink" => nil,
        "minLevelForFlea" => nil
      }
    else
      _ -> nil
    end
  end

  # JSON `containsItems` is `[%{"item" => <id>, "count" => n, ...}]`; the
  # old GraphQL shape (which `Items.Sync.sole_contained_item_id/1` matches
  # on) is `[%{"item" => %{"id" => <id>}}]`.
  defp contains_items(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"item" => id} when is_binary(id) -> [%{"item" => %{"id" => id}}]
      _ -> []
    end)
  end

  defp contains_items(_), do: []

  # JSON `sellToTrader` / `buyFromTrader` → the GraphQL `sellFor`/`buyFor`
  # shape with a `vendor`. The trader id is resolved to its english name +
  # slug; entries whose trader we can't resolve carry a nil vendor name
  # and are dropped downstream by `Items.Sync.reject_nil_vendor/1`.
  defp trader_prices(list, traders) when is_list(list) do
    Enum.map(list, fn p ->
      trader = Map.get(traders, p["trader"], %{})

      %{
        "price" => p["price"],
        "priceRUB" => p["priceRUB"],
        "currency" => p["currency"],
        "vendor" => %{
          "name" => trader["name"],
          "normalizedName" => trader["normalizedName"]
        }
      }
    end)
  end

  defp trader_prices(_, _), do: []

  # Reconstruct the synthetic "Flea Market" vendor row GraphQL folded into
  # `sellFor`/`buyFor`. The sell price is the item's `lastLowPrice` and the
  # buy price its `avg24hPrice` — verified to match the GraphQL resolver's
  # own values. Only emitted when the relevant price is present (items not
  # on the flea have neither, exactly as GraphQL omitted the entry).
  defp flea_sell(%{"lastLowPrice" => price}) when is_integer(price), do: [flea_row(price)]
  defp flea_sell(_), do: []

  defp flea_buy(%{"avg24hPrice" => price}) when is_integer(price), do: [flea_row(price)]
  defp flea_buy(_), do: []

  defp flea_row(price) do
    %{
      "price" => price,
      "priceRUB" => price,
      "currency" => "RUB",
      "vendor" => %{"name" => @flea_market_name, "normalizedName" => @flea_market_slug}
    }
  end

  # ── Ammo adapter ───────────────────────────────────────

  # Only rounds carry the ammo ballistics fragment. Weapon presets,
  # magazines, ammo *boxes* (ItemPropertiesAmmoBox) etc. are excluded.
  defp ammo?(%{"properties" => %{"propertiesType" => "ItemPropertiesAmmo"}}), do: true
  defp ammo?(_), do: false

  # Flatten a round's `properties` fragment (plus its translated identity
  # fields) into the shape `EftBuddy.Ammo.Sync` consumes. The sync coerces
  # every numeric via `to_float` / integer guards, so a missing/odd value
  # never blows up the insert.
  defp ammo_to_map(item, locale) do
    props = item["properties"] || %{}

    %{
      "id" => item["id"],
      "name" => translate(item["name"], locale),
      "shortName" => translate(item["shortName"], locale),
      "normalizedName" => item["normalizedName"],
      "caliber" => props["caliber"],
      "ammoType" => props["ammoType"],
      "damage" => props["damage"],
      "penetrationPower" => props["penetrationPower"],
      "penetrationChance" => props["penetrationChance"],
      "armorDamage" => props["armorDamage"],
      "ricochetChance" => props["ricochetChance"],
      "accuracyModifier" => props["accuracyModifier"],
      "recoilModifier" => props["recoilModifier"],
      "initialSpeed" => props["initialSpeed"],
      "projectileCount" => props["projectileCount"],
      "lightBleedModifier" => props["lightBleedModifier"],
      "heavyBleedModifier" => props["heavyBleedModifier"],
      "stackMaxSize" => props["stackMaxSize"],
      "tracer" => props["tracer"],
      "tracerColor" => props["tracerColor"]
    }
  end

  # ── Armor plate adapter ────────────────────────────────

  # A body ballistic plate: the armor-attachment fragment with a real
  # `armorType` ("Heavy"/"Light"). This is exactly the tarkov.dev "Armor
  # Plate" category (38 items) and excludes the face-shields / visors /
  # ear covers, which carry `armorType: "None"`.
  defp plate?(%{
         "properties" => %{
           "propertiesType" => "ItemPropertiesArmorAttachment",
           "armorType" => type
         }
       })
       when type in ["Heavy", "Light"],
       do: true

  defp plate?(_), do: false

  # Flatten a plate's `properties` into the shape `EftBuddy.Armor.Sync`
  # consumes. Name/icon/price come from the linked item, so they're not
  # duplicated here. The sync coerces every numeric, so a missing/odd
  # value never breaks the insert.
  defp plate_to_map(item) do
    props = item["properties"] || %{}

    %{
      "id" => item["id"],
      "class" => props["class"],
      "durability" => props["durability"],
      "material" => props["material"],
      "armorType" => props["armorType"],
      "bluntThroughput" => props["bluntThroughput"],
      "speedPenalty" => props["speedPenalty"],
      "turnPenalty" => props["turnPenalty"],
      "ergoPenalty" => props["ergoPenalty"],
      "repairCost" => props["repairCost"]
    }
  end

  # ── Barters / crafts adapters ──────────────────────────

  defp barter_to_graphql(b, traders) do
    %{
      "id" => b["id"],
      # The JSON API names the trader-loyalty level `minTraderLevel`;
      # GraphQL called it `level`.
      "level" => b["minTraderLevel"],
      "buyLimit" => b["buyLimit"],
      "trader" => trader_ref(b["trader"], traders),
      "taskUnlock" => task_unlock_ref(b["taskUnlock"]),
      "requiredItems" => Enum.map(List.wrap(b["requiredItems"]), &contained_item/1),
      # JSON gives a single `offeredItem`; GraphQL had a `rewardItems`
      # list (always length 1 for barters).
      "rewardItems" => contained_item_list(b["offeredItem"])
    }
  end

  defp craft_to_graphql(c, stations) do
    %{
      "id" => c["id"],
      "duration" => c["duration"],
      "level" => c["level"],
      "station" => station_ref(c["station"], stations),
      "taskUnlock" => task_unlock_ref(c["taskUnlock"]),
      "requiredItems" => Enum.map(List.wrap(c["requiredItems"]), &contained_item/1),
      "rewardItems" => contained_item_list(c["productItem"])
    }
  end

  defp trader_ref(trader_id, traders) when is_binary(trader_id) do
    trader = Map.get(traders, trader_id, %{})
    %{"id" => trader_id, "normalizedName" => trader["normalizedName"]}
  end

  defp trader_ref(_, _), do: nil

  defp station_ref(station_id, stations) when is_binary(station_id) do
    %{"id" => station_id, "normalizedName" => Map.get(stations, station_id)}
  end

  defp station_ref(_, _), do: nil

  # JSON stores `taskUnlock` as a bare task id (or null); GraphQL wrapped
  # it as `%{"id" => ...}`.
  defp task_unlock_ref(id) when is_binary(id), do: %{"id" => id}
  defp task_unlock_ref(_), do: nil

  # JSON contained-item: `%{"item" => <id>, "count" => n, "attributes" =>
  # %{...}}`. GraphQL shape: `%{"item" => %{"id" => id}, "count" => n,
  # "quantity" => n, "attributes" => [%{"name", "value"}]}`. `count` and
  # `quantity` were always equal in the GraphQL data, so we mirror `count`
  # into `quantity`.
  defp contained_item(%{"item" => id} = ci) when is_binary(id) do
    %{
      "item" => %{"id" => id},
      "count" => ci["count"],
      "quantity" => ci["count"],
      "attributes" => attributes_list(ci["attributes"])
    }
  end

  defp contained_item(_), do: nil

  defp contained_item_list(ci) do
    case contained_item(ci) do
      nil -> []
      row -> [row]
    end
  end

  # JSON attributes are a flat map (`%{"minLevel" => 39}`); GraphQL gave a
  # `[%{"name", "value"}]` list, which `Items.Sync.encode_attributes/1`
  # collapses back to a flat map. Values are stringified to match the
  # GraphQL `String` type.
  defp attributes_list(attrs) when is_map(attrs) do
    Enum.map(attrs, fn {k, v} -> %{"name" => k, "value" => to_string_value(v)} end)
  end

  defp attributes_list(_), do: []

  defp to_string_value(v) when is_binary(v), do: v
  defp to_string_value(nil), do: nil
  defp to_string_value(v), do: to_string(v)

  # ── Tasks adapter ──────────────────────────────────────

  defp task_to_graphql(t, traders, maps, locale) do
    %{
      "id" => t["id"],
      "name" => translate(t["name"], locale),
      "normalizedName" => t["normalizedName"],
      "wikiLink" => t["wikiLink"],
      "taskImageLink" => t["taskImageLink"],
      "experience" => t["experience"],
      "minPlayerLevel" => t["minPlayerLevel"],
      "kappaRequired" => t["kappaRequired"],
      "lightkeeperRequired" => t["lightkeeperRequired"],
      "restartable" => t["restartable"],
      "factionName" => t["factionName"],
      "trader" => full_trader_ref(t["trader"], traders),
      "map" => Map.get(maps, t["map"]),
      "traderRequirements" =>
        Enum.map(List.wrap(t["traderRequirements"]), fn req ->
          %{
            "trader" => full_trader_ref(req["trader"], traders),
            "requirementType" => req["requirementType"],
            "compareMethod" => req["compareMethod"],
            "value" => req["value"]
          }
        end),
      "taskRequirements" =>
        Enum.map(List.wrap(t["taskRequirements"]), fn req ->
          %{"task" => id_ref(req["task"]), "status" => req["status"]}
        end),
      "objectives" =>
        Enum.map(List.wrap(t["objectives"]), &objective_to_graphql(&1, traders, maps, locale)),
      "startRewards" => rewards_to_graphql(t["startRewards"], traders),
      "finishRewards" => rewards_to_graphql(t["finishRewards"], traders)
    }
  end

  # GraphQL's top-level task `trader` carried `{id, name, normalizedName,
  # imageLink}`; requirement/reward trader refs only carried
  # `{id, name, normalizedName}` but `Tasks.Sync` only ever reads
  # `normalizedName` (and `name`/`imageLink` for the portrait), so a
  # single re-inflater covers both.
  defp full_trader_ref(trader_id, traders) when is_binary(trader_id) do
    trader = Map.get(traders, trader_id, %{})

    %{
      "id" => trader_id,
      "name" => trader["name"],
      "normalizedName" => trader["normalizedName"],
      "imageLink" => trader["imageLink"]
    }
  end

  defp full_trader_ref(_, _), do: nil

  defp id_ref(id) when is_binary(id), do: %{"id" => id}
  defp id_ref(_), do: nil

  # Objective subtype fields. The JSON `type` strings are identical to the
  # GraphQL ones, so `Tasks.Sync` stores them as-is. Each id reference the
  # GraphQL inline-fragments exposed as a nested object is re-inflated
  # from its bare-id JSON form into the `%{"id" => ...}` / `[%{"id" =>
  # ...}]` shape `Tasks.Sync.build_objective_payload/3` resolves.
  defp objective_to_graphql(obj, traders, maps, locale) do
    %{
      "id" => obj["id"],
      "type" => obj["type"],
      "description" => translate(obj["description"], locale),
      "optional" => obj["optional"],
      "count" => obj["count"],
      "foundInRaid" => obj["foundInRaid"],
      "targetNames" => obj["targetNames"],
      "shotType" => obj["shotType"],
      "bodyParts" => obj["bodyParts"],
      "exitStatus" => obj["exitStatus"],
      "exitName" => obj["exitName"],
      "compareMethod" => obj["compareMethod"],
      "value" => obj["value"],
      "level" => obj["level"],
      "status" => obj["status"],
      "playerLevel" => obj["playerLevel"],
      # Objective maps are bare ids in JSON; `Tasks.Sync.upsert_maps/2`
      # reads `name`/`normalizedName` off them (as a maps-table fallback),
      # so re-inflate the full ref from the maps index — a bare `%{"id"}`
      # would let it overwrite good rows with nil names.
      "maps" => map_ref_list(obj["maps"], maps),
      "items" => id_ref_list(obj["items"]),
      "markerItem" => id_ref(obj["markerItem"]),
      "questItem" => id_ref(obj["questItem"]),
      "useAny" => id_ref_list(obj["useAny"]),
      "item" => id_ref(obj["item"]),
      # `Tasks.Sync.resolve_trader_ref/2` keys on `normalizedName`; the
      # JSON objective `trader` is a bare id, so re-inflate the slug from
      # the trader index (trader-level / trader-standing objectives only).
      "trader" => slug_ref(obj["trader"], traders),
      "task" => id_ref(obj["task"]),
      "skillLevel" => skill_level(obj),
      "requiredKeys" => required_keys(obj["requiredKeys"])
    }
  end

  # Resolve a bare trader id to the `%{"normalizedName" => slug}` shape
  # `Tasks.Sync.resolve_trader_ref/2` expects.
  defp slug_ref(trader_id, traders) when is_binary(trader_id) do
    case Map.get(traders, trader_id) do
      %{"normalizedName" => slug} -> %{"normalizedName" => slug}
      _ -> nil
    end
  end

  defp slug_ref(_, _), do: nil

  defp map_ref_list(ids, maps) when is_list(ids) do
    Enum.flat_map(ids, fn
      id when is_binary(id) -> List.wrap(Map.get(maps, id))
      _ -> []
    end)
  end

  defp map_ref_list(_, _), do: nil

  # GraphQL exposed the skill objective as `skillLevel { name level }`;
  # the JSON API flattens it to `skill` (name) + `level`.
  defp skill_level(%{"skill" => name, "level" => level}) when is_binary(name),
    do: %{"name" => name, "level" => level}

  defp skill_level(_), do: nil

  defp id_ref_list(ids) when is_list(ids) do
    Enum.flat_map(ids, fn
      id when is_binary(id) -> [%{"id" => id}]
      _ -> []
    end)
  end

  defp id_ref_list(_), do: nil

  # `requiredKeys` is `[[<id>]]` (a list of alternative key-sets) in the
  # JSON API; GraphQL nested each id as `%{"id" => ...}`. `Tasks.Sync`
  # flattens and resolves, so we just re-inflate the leaf ids.
  defp required_keys(groups) when is_list(groups) do
    Enum.map(groups, fn group -> id_ref_list(group) || [] end)
  end

  defp required_keys(_), do: nil

  # GraphQL `startRewards`/`finishRewards` shape. Item rewards used
  # `quantity`; the JSON API uses `count`. Trader refs (standing /
  # unlock / offer) are bare ids that `Tasks.Sync` resolves by
  # `normalizedName`, so re-inflate the slug from the trader index.
  defp rewards_to_graphql(nil, _traders), do: nil

  defp rewards_to_graphql(rewards, traders) do
    %{
      "items" =>
        Enum.map(List.wrap(rewards["items"]), fn entry ->
          %{"item" => id_ref(entry["item"]), "quantity" => entry["count"]}
        end),
      "traderStanding" =>
        Enum.map(List.wrap(rewards["traderStanding"]), fn entry ->
          %{"trader" => slug_ref(entry["trader"], traders), "standing" => entry["standing"]}
        end),
      "skillLevelReward" =>
        Enum.map(List.wrap(rewards["skillLevelReward"]), fn entry ->
          %{"name" => entry["name"] || entry["skill"], "level" => entry["level"]}
        end),
      # GraphQL `traderUnlock` entries were the trader ref directly;
      # `Tasks.Sync.replace_trader_unlocks/3` calls `resolve_trader_ref/2`
      # on each entry, so each must carry `normalizedName`.
      "traderUnlock" =>
        rewards["traderUnlock"] |> List.wrap() |> Enum.map(&slug_ref(&1, traders)),
      "offerUnlock" =>
        Enum.map(List.wrap(rewards["offerUnlock"]), fn entry ->
          %{
            "trader" => slug_ref(entry["trader"], traders),
            "level" => entry["level"],
            "item" => id_ref(entry["item"])
          }
        end)
    }
  end

  # ── Maps adapter ───────────────────────────────────────

  defp map_to_graphql(m, mobs, containers, weapons, locale) do
    %{
      "id" => m["id"],
      "tarkovDataId" => m["tarkovDataId"],
      "name" => translate(m["name"], locale),
      "normalizedName" => m["normalizedName"],
      "nameId" => m["nameId"],
      "wiki" => m["wiki"],
      "description" => translate(m["description"], locale),
      "enemies" => translate_list(m["enemies"], locale),
      "raidDuration" => m["raidDuration"],
      "players" => m["players"],
      "minPlayerLevel" => m["minPlayerLevel"],
      "maxPlayerLevel" => m["maxPlayerLevel"],
      "accessKeysMinPlayerLevel" => m["accessKeysMinPlayerLevel"],
      "accessKeys" => id_ref_list(m["accessKeys"]) || [],
      "bosses" => Enum.map(List.wrap(m["bosses"]), &boss_to_graphql(&1, mobs, locale)),
      "extracts" => Enum.map(List.wrap(m["extracts"]), &extract_to_graphql(&1, locale)),
      "transits" => Enum.map(List.wrap(m["transits"]), &transit_to_graphql(&1, locale)),
      "locks" => Enum.map(List.wrap(m["locks"]), &lock_to_graphql/1),
      "hazards" =>
        Enum.map(List.wrap(m["hazards"]), &hazard_to_graphql(&1, locale)) ++
          artillery_hazards(m["artillery"]),
      "spawns" => Enum.map(List.wrap(m["spawns"]), &spawn_to_graphql/1),
      "lootContainers" =>
        Enum.map(
          List.wrap(m["lootContainers"]),
          &loot_container_to_graphql(&1, containers, locale)
        ),
      "stationaryWeapons" =>
        Enum.map(
          List.wrap(m["stationaryWeapons"]),
          &stationary_weapon_to_graphql(&1, weapons, locale)
        ),
      "switches" => Enum.map(List.wrap(m["switches"]), &switch_to_graphql/1)
    }
  end

  defp stationary_weapon_to_graphql(sw, weapons, locale) do
    weapon = Map.get(weapons, sw["stationaryWeapon"], %{})

    %{
      "name" => translate(weapon["name"], locale),
      "normalizedName" => weapon["normalizedName"],
      "position" => sw["position"]
    }
  end

  defp switch_to_graphql(s) do
    %{
      "id" => s["id"],
      "switchType" => s["switchType"],
      "position" => s["position"]
    }
  end

  @doc false
  # Public only so it can be unit-tested directly; there is no HTTP stub in
  # this suite, and the spawnKey/portrait plumbing below is worth pinning.
  def boss_to_graphql(b, mobs, locale) do
    mob = Map.get(mobs, b["mob"], %{})

    %{
      "boss" => %{
        "id" => mob["id"] || b["mob"],
        "name" => translate(mob["name"], locale),
        "normalizedName" => mob["normalizedName"],
        "imagePortraitLink" => mob["imagePortraitLink"]
      },
      "spawnChance" => b["spawnChance"],
      "spawnTrigger" => b["spawnTrigger"],
      "spawnTime" => b["spawnTime"],
      "spawnTimeRandom" => b["spawnTimeRandom"],
      "spawnLocations" =>
        Enum.map(List.wrap(b["spawnLocations"]), fn loc ->
          %{
            # The raw zone key, joined against `spawns[].zoneName` to decide
            # which spawn points belong to this boss. Upstream exposes both
            # `spawnKey` and an untranslated `name` (both raw, e.g.
            # "ZoneDormitory"), so the name is a safe fallback - but it has to
            # be read *before* translation, or the key becomes "Dorms" and
            # matches nothing.
            "spawnKey" => loc["spawnKey"] || loc["name"],
            "name" => translate(loc["name"], locale),
            "chance" => loc["chance"],
            "positions" => List.wrap(loc["positions"])
          }
        end),
      "escorts" =>
        Enum.map(List.wrap(b["escorts"]), fn e ->
          escort_mob = Map.get(mobs, e["mob"], %{})

          %{
            "boss" => %{
              "id" => escort_mob["id"] || e["mob"],
              "name" => translate(escort_mob["name"], locale),
              "normalizedName" => escort_mob["normalizedName"],
              # Escorts get cards of their own on the map page, so they need
              # the same portrait the boss carries.
              "imagePortraitLink" => escort_mob["imagePortraitLink"]
            },
            "amount" =>
              Enum.map(List.wrap(e["amount"]), fn a ->
                %{"count" => a["count"], "chance" => a["chance"]}
              end)
          }
        end)
    }
  end

  defp extract_to_graphql(ex, locale) do
    %{
      "id" => ex["id"],
      "name" => translate(ex["name"], locale),
      "faction" => ex["faction"],
      "position" => ex["position"],
      "transferItem" => transfer_item(ex["transferItem"])
    }
  end

  defp transfer_item(%{"item" => id} = ti) when is_binary(id) do
    %{"item" => %{"id" => id}, "count" => ti["count"]}
  end

  defp transfer_item(_), do: nil

  defp transit_to_graphql(tr, locale) do
    %{
      "id" => tr["id"],
      "description" => translate(tr["description"], locale),
      "conditions" => tr["conditions"],
      "position" => tr["position"],
      "map" => id_ref(tr["map"])
    }
  end

  defp lock_to_graphql(l) do
    %{
      "lockType" => l["lockType"],
      "needsPower" => l["needsPower"],
      "position" => l["position"],
      "key" => id_ref(l["key"])
    }
  end

  defp hazard_to_graphql(h, locale) do
    %{
      "hazardType" => h["hazardType"],
      "name" => translate(h["name"], locale),
      "position" => h["position"]
    }
  end

  # Mortar / artillery strike zones live in a separate top-level `artillery`
  # object (`artillery.zones`), not in `hazards` — they're present on Customs,
  # Woods, Shoreline, Reserve and Terminal. Each zone is an area with a center
  # `position`; fold them into the hazards list as a `"mortar"` kind so they
  # flow through the same sync + marker pipeline as minefields and snipers.
  defp artillery_hazards(%{"zones" => zones}) when is_list(zones) do
    for z <- List.wrap(zones), is_map(z["position"]) do
      %{"hazardType" => "mortar", "name" => "Mortar", "position" => z["position"]}
    end
  end

  defp artillery_hazards(_), do: []

  defp spawn_to_graphql(s) do
    %{
      "zoneName" => s["zoneName"],
      "sides" => s["sides"],
      "categories" => s["categories"],
      "position" => s["position"]
    }
  end

  defp loot_container_to_graphql(lc, containers, locale) do
    container = Map.get(containers, lc["lootContainer"], %{})

    %{
      "lootContainer" => %{
        "name" => translate(container["name"], locale),
        "normalizedName" => container["normalizedName"]
      },
      "position" => lc["position"]
    }
  end

  # ── Hideout adapter ────────────────────────────────────

  defp station_to_graphql(station, station_refs, traders, locale) do
    %{
      "name" => translate(station["name"], locale),
      "normalizedName" => station["normalizedName"],
      "levels" =>
        Enum.map(List.wrap(station["levels"]), fn level ->
          %{
            "level" => level["level"],
            "itemRequirements" =>
              Enum.map(List.wrap(level["itemRequirements"]), fn req ->
                # JSON uses `count`; GraphQL used `quantity`.
                %{"quantity" => req["count"], "item" => id_ref(req["item"])}
              end),
            "stationLevelRequirements" =>
              Enum.map(List.wrap(level["stationLevelRequirements"]), fn req ->
                %{"level" => req["level"], "station" => Map.get(station_refs, req["station"])}
              end),
            "skillRequirements" =>
              Enum.map(List.wrap(level["skillRequirements"]), fn req ->
                %{"level" => req["level"], "name" => translate(req["skill"], locale)}
              end),
            "traderRequirements" =>
              Enum.map(List.wrap(level["traderRequirements"]), fn req ->
                # JSON uses `value` for the required loyalty level.
                %{"level" => req["value"], "trader" => Map.get(traders, req["trader"])}
              end)
          }
        end)
    }
  end

  # ── Translation ────────────────────────────────────────

  # Every translatable field's *value* is itself the lookup key into the
  # `_en` locale document, so substitution is a plain map lookup. Falls
  # back to the value itself when a key is missing (matches the upstream
  # generator's own en fallback) so a single missing key never blanks a
  # field.
  defp translate(nil, _locale), do: nil
  defp translate(value, locale) when is_binary(value), do: Map.get(locale, value, value)
  defp translate(value, _locale), do: value

  defp translate_list(values, locale) when is_list(values) do
    Enum.map(values, &translate(&1, locale))
  end

  defp translate_list(_, _), do: []

  # ── HTTP ───────────────────────────────────────────────

  # Fetch + decode a JSON document. Returns the decoded top-level map
  # (`%{"data" => ..., "translations" => ...}` for most endpoints, a bare
  # map for the `_en` locales). Reuses the shared transient-retry
  # predicate (Cloudflare 1102 fast-fail, transport retries) the GraphQL
  # path used.
  @doc false
  def get_json(path) do
    url = base_url() <> path

    case Req.get(url,
           receive_timeout: @http_timeout,
           connect_options: [timeout: 5_000],
           retry: &Helpers.retry_transient?/2,
           max_retries: 3,
           headers: [{"user-agent", "EftBuddy/1.0 (+json-sync)"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        decode_body(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fetch a `_en` locale document and return its `data` map (the
  # `%{placeholder_key => translated_value}` dictionary). A translatable
  # endpoint MUST have a usable locale — failing here surfaces as a failed
  # fetch so the sync never writes placeholder strings or prunes against a
  # half-translated snapshot.
  defp fetch_locale(path) do
    case get_json(path) do
      {:ok, %{"data" => locale}} when is_map(locale) -> {:ok, locale}
      {:ok, _} -> {:error, {:invalid_locale, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Best-effort locale for `maps/1` only — see the comment there.
  defp fetch_maps_locale(game_mode) do
    case fetch_locale("/#{game_mode}/maps_en") do
      {:ok, locale} ->
        locale

      {:error, reason} ->
        Logger.warning(
          "[TarkovApi] maps locale unavailable (#{inspect(reason)}); syncing with raw names"
        )

        %{}
    end
  end

  # Req decodes `application/json` automatically, but json.tarkov.dev's
  # CDN sometimes serves the documents as `text/plain`; handle both a
  # pre-decoded map and a raw JSON binary.
  defp decode_body(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} = err -> {:error, {:json_decode_failed, err}}
    end
  end

  defp decode_body(other), do: {:error, {:unexpected_body, other}}

  # `barters` / `crafts` return their collection as a bare list under
  # `data`; everything else is keyed by id. This pulls the list out
  # defensively.
  defp data_list(%{"data" => list}) when is_list(list), do: list
  defp data_list(_), do: []

  defp default_mode, do: EftBuddy.GameMode.default()
end
