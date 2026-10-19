defmodule EftBuddy.Ammo do
  @moduledoc """
  The Ammo context: the ballistics catalog behind the `/ammo` page.

  Rounds are synced into the `ammo` table by `EftBuddy.Ammo.Sync` (from the
  tarkov.dev items `properties` fragment), each linked to its `items` row for
  the display name and icon. Ballistics are identical across PVP and PVE, so
  the page is a single, mode-agnostic view.

  `list_rounds/0` does the DB work once; the pure `filter/2` and `group/2`
  helpers then slice that list for the LiveView without further queries.

  Where a round can be bought (trader, flea, barter, craft) used to be derived
  here too, from four `buy_for`/recipe queries rebuilt on every ten-minute price
  tick, and warmed 144 times a day. Nothing ever displayed it, so it is gone
  (audit L1).
  """

  import Ecto.Query

  alias EftBuddy.Ammo.{Caliber, Round}
  alias EftBuddy.Cache
  alias EftBuddy.Repo
  alias EftBuddy.Sortable

  # col → schema field for sorting. Declared here so the page's sortable
  # columns are defined in one place.
  @sort_columns %{
    "name" => :name,
    "damage" => :damage,
    "pen" => :penetration_power,
    "armor" => :armor_damage,
    "pen_chance" => :penetration_chance,
    "ricochet" => :ricochet_chance,
    "accuracy" => :accuracy_modifier,
    "recoil" => :recoil_modifier,
    "velocity" => :initial_speed,
    "light_bleed" => :light_bleed_modifier,
    "heavy_bleed" => :heavy_bleed_modifier,
    "stack" => :stack_max_size
  }

  # Force the `:<col>_asc` / `:<col>_desc` atoms into existence at compile
  # time so `EftBuddyWeb.UI.next_sort/2`'s `String.to_existing_atom/1`
  # lookup always resolves them (never falls back to `:default` for a
  # legitimate column click).
  @sort_atoms Sortable.atoms(Map.keys(@sort_columns))

  @doc false
  def sort_atoms, do: @sort_atoms

  @doc """
  Every ammo round, each with its `:item` preloaded.

  Bounded to the ~200 rounds in the game, so the LiveView holds the result
  and derives its filtered views from it without re-querying on every
  keystroke. Cached under the two feeds that write it: ballistics change on a
  game patch (AmmoSync), names and icons with the catalog (ItemsSync), so the
  ten-minute price tick never touches it.
  """
  def list_rounds do
    Cache.fetch({__MODULE__, :list_rounds}, ["AmmoSync", "ItemsSync"], fn ->
      Round |> preload(:item) |> Repo.all()
    end)
  end

  # ── Pure list helpers (operate on the list_rounds/0 result) ──────────

  @doc "Filter `rounds` by a free-text `query` on the round's name or caliber label."
  def filter(rounds, query) do
    needle = query |> to_string() |> String.trim() |> String.downcase()
    Enum.filter(rounds, &search_match?(&1, needle))
  end

  defp search_match?(_round, ""), do: true

  defp search_match?(round, needle) do
    name = round.item && round.item.name
    label = Caliber.label(round.caliber)

    (is_binary(name) and String.contains?(String.downcase(name), needle)) or
      String.contains?(String.downcase(label), needle)
  end

  @doc """
  Group `rounds` by caliber and sort **within each group** by `sort`,
  returning `[{caliber_enum, label, sorted_rounds}]` in caliber display
  order (empty groups dropped).

  The sort is scoped per block: the caliber order of the page never
  changes, only the ordering of rounds inside each caliber section.
  `sort` is a `:<col>_asc` / `:<col>_desc` atom (or `:default`, which
  sorts by penetration power descending).
  """
  def group(rounds, sort \\ :default)

  # Per-block sort: `sorts` maps a caliber enum to its own sort atom, so
  # each caliber section on the page sorts independently. Calibers absent
  # from the map fall back to `:default`.
  def group(rounds, sorts) when is_map(sorts) do
    group_and_sort(rounds, fn caliber -> Map.get(sorts, caliber, :default) end)
  end

  # Uniform sort: every block sorted the same way.
  def group(rounds, sort) do
    group_and_sort(rounds, fn _caliber -> sort end)
  end

  defp group_and_sort(rounds, sort_for) do
    rounds
    |> Enum.group_by(& &1.caliber)
    |> Enum.map(fn {caliber, group_rounds} ->
      {caliber, Caliber.label(caliber), sort_rounds(group_rounds, sort_for.(caliber))}
    end)
    |> Enum.sort_by(fn {caliber, label, _} -> {Caliber.order(caliber), label} end)
  end

  # Sort a caliber block. `:default` (the unsorted state) puts the strongest
  # round first — penetration power descending, the "best round up top"
  # ordering the ballistics chart wants; any other atom sorts by its column.
  defp sort_rounds(rounds, sort) do
    case Sortable.resolve(sort, @sort_columns) do
      {:default, _dir} -> Enum.sort_by(rounds, & &1.penetration_power, :desc)
      {field, dir} -> Enum.sort_by(rounds, &sort_value(&1, field), dir)
    end
  end

  defp sort_value(round, :name), do: round.item && round.item.name
  defp sort_value(round, field), do: Map.get(round, field)
end
