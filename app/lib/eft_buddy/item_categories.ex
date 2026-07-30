defmodule EftBuddy.ItemCategories do
  @moduledoc """
  Shared item-category groupings.

  A single source of truth for the curated category filter used by both the
  Flea Market and the Items pages, so the two never drift apart. Each group's
  `:categories` list holds the exact `Category.name` values from the
  `categories` table, so they double as filter keys against the items query.
  """

  @groups [
    %{
      id: "containers",
      name: "Containers",
      categories: [
        "Common container",
        "Locking container",
        "Port. container",
        "Random Loot Container"
      ]
    },
    %{
      id: "ammo",
      name: "Ammo",
      categories: ["Ammo", "Rocket", "Ammo container"]
    },
    %{
      id: "keys",
      name: "Keys",
      categories: ["Mechanical Key", "Keycard"]
    },
    %{
      id: "gear",
      name: "Gear",
      categories: [
        "Vis. observ. device",
        "Headwear",
        "Headphones",
        "Arm Band",
        "Armor",
        "Armor Plate",
        "Armored equipment",
        "Backpack",
        "Chest rig",
        "Face Cover"
      ]
    },
    %{
      id: "meds",
      name: "Meds",
      categories: [
        "Stimulant",
        "Medikit",
        "Medical supplies",
        "Medical item",
        "Drug"
      ]
    },
    %{
      id: "mods",
      name: "Mods",
      categories: [
        "UBGL",
        "Stock",
        "Thermal Vision",
        "Night Vision",
        "Ironsight",
        "Foregrip",
        "Flashlight",
        "Assault scope",
        "Auxiliary Mod",
        "Barrel",
        "Bipod",
        "Charging handle",
        "Comb. muzzle device",
        "Comb. tact. device",
        "Compact reflex sight",
        "Cylinder Magazine",
        "Flashhider",
        "Gas block",
        "Handguard",
        "Magazine",
        "Mount",
        "Pistol grip",
        "Receiver",
        "Reflex sight",
        "Scope",
        "Silencer",
        "Special scope",
        "Spring Driven Cylinder"
      ]
    },
    %{
      id: "provisions",
      name: "Provisions",
      categories: ["Food", "Drink"]
    },
    %{
      id: "guns",
      name: "Guns",
      categories: [
        "Sniper rifle",
        "SMG",
        "Shotgun",
        "Rocket Launcher",
        "Marksman rifle",
        "Machinegun",
        "Handgun",
        "Grenade launcher",
        "Assault carbine",
        "Assault rifle",
        "Revolver",
        "Throwable weapon"
      ]
    },
    %{
      id: "special-equipment",
      name: "Special Equipment",
      categories: [
        "Special item",
        "Repair Kits",
        "Radio Transmitter",
        "Portable Range Finder",
        "Planting Kits",
        "Multitools",
        "Mark of the Unheard",
        "Compass",
        "Cultist Amulet"
      ]
    },
    %{
      id: "others",
      name: "Others",
      categories: [
        "Tool",
        "Tapes",
        "Recorder",
        "Other",
        "Notes",
        "Money",
        "Map",
        "Lubricant",
        "Knife",
        "Jewelry",
        "Info",
        "Household goods",
        "Fuel",
        "Flyer",
        "Electronics",
        "Battery",
        "Building material",
        "Dialog Item"
      ]
    }
  ]

  @group_id_to_category_names Map.new(@groups, &{&1.id, &1.categories})

  @category_to_group_id Enum.flat_map(@groups, fn group ->
                          Enum.map(group.categories, &{&1, group.id})
                        end)
                        |> Map.new()

  @doc "The ordered list of category groups (each `%{id, name, categories}`)."
  def groups, do: @groups

  @doc """
  The `Category.name` values belonging to a group id, or `[]` for a nil /
  unknown id (which the query layer treats as "no category filter").
  """
  def names_for(nil), do: []
  def names_for(group_id), do: Map.get(@group_id_to_category_names, group_id, [])

  @doc "The group id a given category belongs to (defaults to \"others\")."
  def group_id_for(nil), do: "others"
  def group_id_for(%{name: name}), do: Map.get(@category_to_group_id, name, "others")

  @doc "Whether the given string is a known group id."
  def valid_id?(id) when is_binary(id), do: Map.has_key?(@group_id_to_category_names, id)
  def valid_id?(_), do: false
end
