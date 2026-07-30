defmodule EftBuddy.Armor do
  @moduledoc """
  The Armor context: the ballistic-plate catalog behind the Plates block
  on the Ballistics page.

  Plates are synced into the `armor_plates` table by `EftBuddy.Armor.Sync`
  (from the tarkov.dev JSON API's "Armor Plate" items). Each plate links
  back to its `items` row for the display name / icon / price; this context
  reads them with that association preloaded and groups them by class for
  the LiveView.
  """

  import Ecto.Query

  alias EftBuddy.Armor.{Material, Plate}
  alias EftBuddy.Repo
  alias EftBuddy.Sortable

  # col → sort key for the plates table. Declared here so the page's
  # sortable columns live in one place (mirrors `Ammo`'s `@sort_columns`).
  # `:name` / `:material` / `:effective_durability` / `:destructibility` /
  # `:explosive_destructibility` are virtual (read via helpers / the material
  # reference); the rest map straight to schema fields.
  @sort_columns %{
    "plate" => :name,
    "material" => :material,
    "destructibility" => :destructibility,
    "explosive" => :explosive_destructibility,
    "type" => :armor_type,
    "durability" => :durability,
    "eff_dur" => :effective_durability,
    "blunt" => :blunt_throughput,
    "speed" => :speed_penalty,
    "turn" => :turn_penalty,
    "ergo" => :ergo_penalty,
    "repair" => :repair_cost
  }

  # Force the `:<col>_asc` / `:<col>_desc` atoms into existence at compile
  # time so `EftBuddyWeb.UI.next_sort/2`'s `String.to_existing_atom/1`
  # lookup always resolves a plate column click.
  @sort_atoms Sortable.atoms(Map.keys(@sort_columns))

  @doc "Every armor plate, with its `:item` preloaded."
  def list_plates do
    Plate
    |> preload(:item)
    |> Repo.all()
  end

  @doc "The sortable plate column keys (the `col` values `sort_header/1` emits)."
  def sort_columns, do: Map.keys(@sort_columns)

  @doc false
  def sort_atoms, do: @sort_atoms

  @doc """
  Group `plates` by protection class (highest class first) and sort
  **within each class** by `sort`, returning `[{class, [plate]}]`.

  The class order of the page never changes — only the ordering of plates
  inside each class section — so sorting never scrambles the grouping.
  `sort` is a `:<col>_asc` / `:<col>_desc` atom, or `:default` (toughest
  plate first by effective durability, ties broken by name).
  """
  def group_by_class(plates, sort \\ :default)

  # Per-block sort: `sorts` maps a class to its own sort atom, so each
  # class section on the page sorts independently. Classes absent from the
  # map fall back to `:default`.
  def group_by_class(plates, sorts) when is_map(sorts) do
    group_and_sort_by_class(plates, fn class -> Map.get(sorts, class, :default) end)
  end

  # Uniform sort: every class block sorted the same way.
  def group_by_class(plates, sort) do
    group_and_sort_by_class(plates, fn _class -> sort end)
  end

  defp group_and_sort_by_class(plates, sort_for) do
    plates
    |> Enum.group_by(& &1.class)
    |> Enum.map(fn {class, group} -> {class, sort_plates(group, sort_for.(class))} end)
    |> Enum.sort_by(fn {class, _} -> -class end)
  end

  # Sort a class block. `:default` (the unsorted state) puts the toughest
  # plate first — effective durability desc, ties broken by name asc, the
  # "best plate in this class up top" ordering; any other atom sorts by its
  # column.
  defp sort_plates(plates, sort) do
    case Sortable.resolve(sort, @sort_columns) do
      {:default, _dir} ->
        Enum.sort_by(plates, &{-(effective_durability(&1) || 0), plate_name(&1)})

      {field, dir} ->
        Enum.sort_by(plates, &sort_value(&1, field), dir)
    end
  end

  defp sort_value(plate, :name), do: plate_name(plate)
  defp sort_value(plate, :material), do: Material.label(plate.material)
  defp sort_value(plate, :armor_type), do: plate.armor_type || ""
  defp sort_value(plate, :effective_durability), do: effective_durability(plate) || 0
  defp sort_value(plate, :destructibility), do: Material.destructibility(plate.material) || 0

  defp sort_value(plate, :explosive_destructibility),
    do: Material.explosive_destructibility(plate.material) || 0

  defp sort_value(plate, field) do
    case Map.get(plate, field) do
      nil -> 0
      value -> value
    end
  end

  defp effective_durability(plate),
    do: Material.effective_durability(plate.durability, plate.material)

  defp plate_name(%{item: %{name: name}}) when is_binary(name), do: name
  defp plate_name(_), do: ""
end
