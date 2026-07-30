defmodule EftBuddyWeb.MapsLive.Markers do
  @moduledoc """
  Builds the clickable markers the interactive map viewer draws, and the
  descriptor list that tells the client how to render each marker *type*.

  Markers carry the game `(x, z)` position; the client projects them onto the
  base art. Only entities with a position get one. `href` is the in-app link
  target (the Items tab for keys and transfer items, the destination map page
  for transits), or `nil` for a plain pin.

  ## Spawn and boss pins

  Boss pins follow tarkov.dev's model: we iterate **physical spawn points**
  (`EftBuddy.Maps.Spawn`) rather than boss spawn *zones*, and join each one
  against `EftBuddy.Maps.Boss`'s `spawn_locations[].spawn_key`. So a zone with
  seven positions renders seven pins rather than one.

  A point can carry more than one pin. Bosses are split across four layers
  (`@boss_layers`), and a point yields one pin per layer that claims it: bosses
  sharing a layer share a pin — Terminal's five generic bosses on one point stay
  a single pin naming all five — while Factory's Tagilla and Cultist Priest get
  a pin each, because the cultist is a distinct threat and lumping it under the
  generic boss icon hid it completely.

  A boss-category point that no boss claims is not a boss spawn at all: it is
  an ordinary scav point (or is dropped when it isn't `bot` + `scav`). 391
  points across the roster are affected, 164 of them on Streets.

  ## Marker types

  `@catalog` is the single declaration of every marker type's icon, label and
  default visibility. `build/1` produces types, `descriptors/1` produces their
  config, and the client renders whatever it is handed — nothing about a marker
  type is declared in JavaScript. Only the layers a map actually has are
  described, so a map without rogues shows no Rogues toggle.
  """

  use EftBuddyWeb, :verified_routes

  @marker_base "/images/maps/markers"

  # Display order for the toggle panel.
  #
  # `hidden: true` means the layer starts switched off. Everything that is
  # dense (spawns, landmines, stashes) or niche (switches, stationary weapons)
  # defaults off so a map opens readable.
  @catalog [
    %{type: "extract_pmc", label: "PMC extracts", icon: "extract_pmc.webp"},
    %{type: "extract_scav", label: "Scav extracts", icon: "extract_scav.webp"},
    %{type: "extract_shared", label: "Shared extracts", icon: "extract_shared.webp"},
    %{type: "transit", label: "Transits", icon: "extract_transit.webp"},
    %{type: "lock", label: "Keyed doors", icon: "lock.webp"},
    %{type: "hazard_sniper", label: "Sniper zones", icon: "hazard_sniper.webp"},
    %{type: "hazard_mortar", label: "Mortars", icon: "hazard_mortar.webp"},
    %{type: "hazard", label: "Hazards", icon: "hazard.webp"},
    %{type: "hazard_minefield", label: "Landmines", icon: "hazard_minefield.webp", hidden: true},
    %{type: "stash", label: "Stashes", icon: "stash.webp", hidden: true},
    %{type: "spawn_pmc", label: "PMC spawns", icon: "spawn_pmc.webp", hidden: true},
    %{type: "spawn_scav", label: "Scav spawns", icon: "spawn_scav.webp", hidden: true},
    # Reuses the sniper-zone art deliberately: a scav sniper nest and a sniper
    # danger zone read as the same thing to a player, and it needs no new asset.
    %{type: "spawn_sniper_scav", label: "Sniper scavs", icon: "hazard_sniper.webp", hidden: true},
    %{type: "spawn_boss", label: "Boss spawns", icon: "spawn_boss.webp", hidden: true},
    %{type: "spawn_cultist", label: "Cultist Priest", icon: "spawn_cultist.webp", hidden: true},
    %{type: "spawn_rogue", label: "Rogues", icon: "spawn_rogue.webp", hidden: true},
    %{type: "spawn_goons", label: "The Goons", icon: "spawn_goons.webp", hidden: true},
    %{type: "switch", label: "Switches", icon: "switch.webp", hidden: true},
    %{
      type: "stationary_weapon",
      label: "Stationary weapons",
      icon: "stationary_weapon.webp",
      hidden: true
    }
  ]

  # Which layer a boss belongs to, keyed on `normalized_name`. Three factions
  # players treat as distinct threats get their own pin and toggle; every other
  # boss shares the generic one.
  #
  # Keyed on `knight` because that is what the API calls the Goons' boss row —
  # Big Pipe and Birdeye are escorts with no `spawnLocations`, so they produce
  # no markers of their own and one toggle covers the squad.
  @boss_layers %{
    "cultist-priest" => "spawn_cultist",
    "rogue" => "spawn_rogue",
    "knight" => "spawn_goons"
  }
  @default_boss_layer "spawn_boss"

  @doc """
  Every marker for `map`, in layer order.
  """
  def build(map) do
    extract_markers(map.extracts) ++
      lock_markers(map.locks) ++
      hazard_markers(map.hazards) ++
      transit_markers(map.transits) ++
      spawn_markers(map.spawns, map.bosses, map.bounds) ++
      stash_markers(map.loot_containers) ++
      stationary_weapon_markers(map.stationary_weapons) ++
      switch_markers(map.switches)
  end

  @doc """
  Ordered layer descriptors for exactly the types present in `markers`.

  Each is `%{"type", "label", "icon", "hidden"}`. `hidden` is always present so
  the client needs no defaulting, and the order is stable across renders so the
  toggle panel never reshuffles.
  """
  def descriptors(markers) do
    present = MapSet.new(markers, & &1["type"])

    Enum.flat_map(@catalog, fn entry ->
      if MapSet.member?(present, entry.type), do: [descriptor(entry)], else: []
    end)
  end

  @doc "The catalog, for tests that assert on the layer set or its assets."
  def catalog, do: @catalog

  defp descriptor(entry) do
    %{
      "type" => entry.type,
      "label" => entry.label,
      "icon" => "#{@marker_base}/#{entry.icon}",
      "hidden" => Map.get(entry, :hidden, false)
    }
  end

  # ── Spawn + boss pins ──────────────────────────────────

  # One pin per physical spawn point *per layer*. See the moduledoc for why this
  # iterates spawns rather than boss spawn locations.
  #
  # A point claimed by bosses on different layers yields one pin each, at the
  # same coordinates — Factory's `BotZone` is Tagilla and the Cultist Priest on
  # the same five positions, and lumping them under one generic pin hid the
  # cultist entirely. They overlap; the layer toggles are what separate them.
  defp spawn_markers(spawns, bosses, bounds) do
    index = boss_zone_index(bosses)

    spawns
    |> Enum.filter(&(located?(&1) and in_bounds?(&1.pos_x, &1.pos_z, bounds)))
    |> Enum.flat_map(fn s ->
      for {type, label} <- spawn_kinds(s, index) do
        %{
          "type" => type,
          "label" => label,
          "x" => s.pos_x,
          "y" => s.pos_y,
          "z" => s.pos_z,
          "href" => nil
        }
      end
    end)
  end

  # `%{spawn_key => [%{slug:, label:}]}`, deduped per zone and kept in the
  # API's own order (which puts a map's headline boss first), so a shared
  # point's popup reads "Reshala, Cultist Priest" rather than alphabetically.
  defp boss_zone_index(bosses) do
    bosses
    |> Enum.flat_map(fn boss ->
      for loc <- boss.spawn_locations || [],
          key = loc["spawn_key"],
          is_binary(key),
          key != "" do
        {key, %{slug: boss.normalized_name, label: boss.name}}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, entries} -> {key, Enum.uniq_by(entries, & &1.slug)} end)
  end

  # The `{type, label}` pairs a spawn point contributes — a list, because a
  # boss point can belong to several layers at once.
  #
  # Bosses sharing a layer share a pin, so Terminal's five generic bosses on
  # `Zone2ScavPort29` still render one pin naming all five, in the API's own
  # order (which puts a map's headline boss first).
  defp spawn_kinds(%{spawn_type: "boss"} = s, index) do
    case Map.get(index, s.zone_name, []) do
      [] ->
        List.wrap(unclaimed_boss_kind(s))

      claimants ->
        claimants
        |> Enum.group_by(&boss_layer/1)
        |> Enum.map(fn {type, group} -> {type, Enum.map_join(group, ", ", &boss_label/1)} end)
        |> Enum.sort_by(&layer_order/1)
    end
  end

  defp spawn_kinds(%{spawn_type: "sniper_scav"}, _index),
    do: [{"spawn_sniper_scav", "Sniper scav"}]

  defp spawn_kinds(%{spawn_type: "scav"}, _index), do: [{"spawn_scav", "Scav spawn"}]
  defp spawn_kinds(%{spawn_type: "pmc"}, _index), do: [{"spawn_pmc", "PMC spawn"}]
  defp spawn_kinds(_s, _index), do: []

  # `Enum.group_by/2` returns map order, which is not the catalog's. Sorting on
  # the catalog index keeps a point's pins in panel order every render.
  @layer_order @catalog |> Enum.map(& &1.type) |> Enum.with_index() |> Map.new()
  defp layer_order({type, _label}), do: Map.get(@layer_order, type, 99)

  # A boss-category point no boss claims via `spawn_key` is not a boss spawn:
  # upstream renders it as a scav when the point is `bot` + `scav`, and drops
  # it otherwise.
  #
  # `List.wrap/1` matters — rows synced before `sides`/`categories` existed read
  # back as `[]`, so an un-synced deploy degrades to "skip" instead of crashing.
  defp unclaimed_boss_kind(s) do
    cats = List.wrap(s.categories)
    sides = List.wrap(s.sides)

    cond do
      "sniper" in cats and "scav" in sides -> {"spawn_sniper_scav", "Sniper scav"}
      "bot" in cats and "scav" in sides -> {"spawn_scav", "Scav spawn"}
      true -> nil
    end
  end

  # A boss whose mob id is missing upstream has no `normalized_name`; it still
  # gets a pin, just in the generic layer.
  defp boss_layer(%{slug: slug}) when is_binary(slug),
    do: Map.get(@boss_layers, slug, @default_boss_layer)

  defp boss_layer(_), do: @default_boss_layer

  defp boss_label(%{label: name}) when is_binary(name) and name != "", do: name
  defp boss_label(_), do: "Boss"

  # tarkov.dev's `positionIsInBounds`: a box test on **raw game coordinates**,
  # not on projected pixels — `getBounds()` swaps the config to `[z, x]` and
  # `pos()` returns `[z, x]`, so the two swaps cancel out.
  #
  # Corner order isn't guaranteed (Factory's is `[[77, -64.5], [-65.5, 67.4]]`),
  # hence min/max rather than comparing against a fixed corner. Applied to
  # spawns only, which is what upstream guards: extracts, keyed doors and
  # transits are a small curated set where dropping one is visible data loss.
  defp in_bounds?(x, z, [[x0, z0], [x1, z1]])
       when is_number(x) and is_number(z) and
              is_number(x0) and is_number(z0) and is_number(x1) and is_number(z1) do
    x >= min(x0, x1) and x <= max(x0, x1) and z >= min(z0, z1) and z <= max(z0, z1)
  end

  defp in_bounds?(_x, _z, _bounds), do: true

  # ── Everything else ────────────────────────────────────

  defp extract_markers(extracts) do
    for ex <- extracts, located?(ex) do
      %{
        "type" => "extract_" <> extract_faction(ex.faction),
        "label" => ex.name,
        "x" => ex.pos_x,
        "y" => ex.pos_y,
        "z" => ex.pos_z,
        "href" => ex.transfer_item && item_link(ex.transfer_item.name)
      }
    end
  end

  # The API only ever returns pmc / scav / shared; anything unexpected falls
  # back to the shared icon so the marker still renders.
  defp extract_faction("pmc"), do: "pmc"
  defp extract_faction("scav"), do: "scav"
  defp extract_faction(_), do: "shared"

  defp lock_markers(locks) do
    for lock <- locks, located?(lock) do
      %{
        "type" => "lock",
        "label" => lock_marker_label(lock),
        "x" => lock.pos_x,
        "y" => lock.pos_y,
        "z" => lock.pos_z,
        "href" => lock.key_item && item_link(lock.key_item.name)
      }
    end
  end

  # Naming the key is the useful part, but "needs power" has to survive it —
  # a powered keyed door needs both, and showing only the key name told the
  # player half the story.
  defp lock_marker_label(%{key_item: %{name: name}} = lock) when is_binary(name) do
    if lock.needs_power, do: name <> " (needs power)", else: name
  end

  defp lock_marker_label(lock), do: lock_label(lock)

  defp lock_label(%{lock_type: type, needs_power: true}) when is_binary(type),
    do: String.capitalize(type) <> " (needs power)"

  defp lock_label(%{lock_type: type}) when is_binary(type), do: String.capitalize(type)
  defp lock_label(_), do: "Locked"

  # One marker per hazard position (so a minefield / sniper zone renders as its
  # full cluster of points, like tarkov.dev), typed by the hazard kind so each
  # gets its own icon and toggle.
  defp hazard_markers(hazards) do
    for hz <- hazards,
        pos <- hazard_positions(hz) do
      %{
        "type" => hazard_marker_type(hz.hazard_type),
        "label" => hazard_label(hz.hazard_type),
        "x" => pos["x"],
        "y" => pos["y"],
        "z" => pos["z"],
        "href" => nil
      }
    end
  end

  # Prefer the full positions list; fall back to the single representative pin
  # for rows synced before positions were stored.
  defp hazard_positions(%{positions: [_ | _] = positions}), do: positions

  defp hazard_positions(%{pos_x: x, pos_z: z} = hz) when is_number(x) and is_number(z),
    do: [%{"x" => x, "y" => hz.pos_y, "z" => z}]

  defp hazard_positions(_), do: []

  # Hazard kinds, each its own marker type + toggle:
  #   * "minefield" → landmines (`hazards`, name DamageType_Landmine)
  #   * "sniper"    → sniper zones (`hazards`, name ScavRole/Marksman)
  #   * "mortar"    → mortar / artillery strike zones (folded in from the
  #                   map's separate `artillery.zones` by `TarkovApi`)
  #   * "hazard"    → the generic environmental hazard the API only lists on
  #                   The Labyrinth (its chamber traps — steam/fire/toxic).
  defp hazard_marker_type("minefield"), do: "hazard_minefield"
  defp hazard_marker_type("sniper"), do: "hazard_sniper"
  defp hazard_marker_type("mortar"), do: "hazard_mortar"
  defp hazard_marker_type(_), do: "hazard"

  defp hazard_label("minefield"), do: "Landmine"
  defp hazard_label("sniper"), do: "Sniper zone"
  defp hazard_label("mortar"), do: "Mortar"
  defp hazard_label(_), do: "Hazard"

  defp transit_markers(transits) do
    for tr <- transits, located?(tr) do
      {label, href} = transit_target(tr)

      %{
        "type" => "transit",
        "label" => label,
        "x" => tr.pos_x,
        "y" => tr.pos_y,
        "z" => tr.pos_z,
        "href" => href
      }
    end
  end

  defp transit_target(%{destination_map: %{} = dest} = tr) do
    {tr.description || "To #{dest.name}", ~p"/maps/#{dest.normalized_name}"}
  end

  defp transit_target(tr), do: {tr.description || "Transit", nil}

  defp stash_markers(containers) do
    for c <- containers, located?(c) do
      %{
        "type" => "stash",
        "label" => c.name || "Stash",
        "x" => c.pos_x,
        "y" => c.pos_y,
        "z" => c.pos_z,
        "href" => nil
      }
    end
  end

  defp stationary_weapon_markers(weapons) do
    for w <- weapons, located?(w) do
      %{
        "type" => "stationary_weapon",
        "label" => w.name || "Stationary weapon",
        "x" => w.pos_x,
        "y" => w.pos_y,
        "z" => w.pos_z,
        "href" => nil
      }
    end
  end

  defp switch_markers(switches) do
    for s <- switches, located?(s) do
      %{
        "type" => "switch",
        "label" => "Switch",
        "x" => s.pos_x,
        "y" => s.pos_y,
        "z" => s.pos_z,
        "href" => nil
      }
    end
  end

  defp located?(%{pos_x: x, pos_z: z}) when is_number(x) and is_number(z), do: true
  defp located?(_), do: false

  defp item_link(name) when is_binary(name), do: "/items?q=" <> URI.encode_www_form(name)
  defp item_link(_), do: nil
end
