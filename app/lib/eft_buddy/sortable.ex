defmodule EftBuddy.Sortable do
  @moduledoc """
  Shared 3-state column-sort plumbing for the browse tables (`Ammo`, `Armor`).

  Pairs with `EftBuddyWeb.UI.sort_header/1` + `EftBuddyWeb.UI.next_sort/2`,
  which encode a table's sort state as a `:<col>_asc` / `:<col>_desc` atom
  (or `:default` when unsorted). Each context declares its own `"col" =>
  field` map; this module owns the two mechanical bits every such table
  otherwise duplicates:

    * `atoms/1` — force the `:<col>_asc` / `:<col>_desc` atoms into
      existence so `next_sort/2`'s `String.to_existing_atom/1` lookup always
      resolves a legitimate column click (never silently falls back to
      `:default`).
    * `resolve/2` — turn a sort atom into `{field, direction}`, or
      `{:default, :desc}` for the unsorted state. What "default" actually
      orders by is intentionally left to the caller (Ammo defaults to
      penetration power desc; Armor to effective durability desc).
  """

  @doc """
  The `:<col>_asc` / `:<col>_desc` atoms for every column in `cols`.

  Call this from a module attribute (e.g. `@sort_atoms
  EftBuddy.Sortable.atoms(Map.keys(@sort_columns))`) so the atoms are minted
  at compile time and embedded as literals in the caller's compiled module —
  which registers them in the runtime atom table when that module loads.
  """
  # Sobelow flags `String.to_atom/1` as a DoS risk (unbounded atom-table growth).
  # False positive: `cols` is a COMPILE-TIME list — every caller invokes this from
  # a module attribute over its own literal `@sort_columns` keys, so the set of
  # atoms is fixed when the module compiles and no user input ever reaches here.
  # Every RUNTIME conversion goes through `String.to_existing_atom/1` and is
  # additionally guarded three ways (an `is_binary` guard, a `rescue
  # ArgumentError`, and a membership check against a compile-time allow-list) —
  # see `EftBuddyWeb.UI.next_sort/2` and the `parse_scope` / `parse_filter`
  # helpers in the Items, Tasks, Events and Intel LiveViews.
  # sobelow_skip ["DOS.StringToAtom"]
  def atoms(cols) do
    for col <- cols, dir <- ~w(asc desc), do: String.to_atom("#{col}_#{dir}")
  end

  @doc """
  Resolve a sort atom to `{field, :asc | :desc}` using `columns` (a
  `"col" => field` map).

  A `:<col>_desc` / `:<col>_asc` atom maps `col` through `columns` to its
  field and carries the direction. `:default` — and any atom whose column
  isn't in `columns` — resolves to `{:default, :desc}`, leaving the caller to
  decide what its default ordering is.
  """
  def resolve(sort, columns) when is_atom(sort) and is_map(columns) do
    string = Atom.to_string(sort)

    cond do
      String.ends_with?(string, "_desc") -> {field(string, "_desc", columns), :desc}
      String.ends_with?(string, "_asc") -> {field(string, "_asc", columns), :asc}
      true -> {:default, :desc}
    end
  end

  defp field(string, suffix, columns) do
    col = String.trim_trailing(string, suffix)
    Map.get(columns, col, :default)
  end
end
