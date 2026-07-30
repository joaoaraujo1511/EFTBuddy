defmodule EftBuddy.Ammo.Caliber do
  @moduledoc """
  Maps the tarkov.dev raw caliber enums (`"Caliber556x45NATO"`,
  `"Caliber12g"`, …) to human display labels and a stable display order
  for the Ballistics page's caliber grouping and filter chips.

  Same idea as `EftBuddy.Items.BackgroundColor`: keep the presentation
  mapping in code (not the DB), with a graceful fallback so a caliber
  introduced by a future game patch never breaks the page — it just
  renders a best-effort label and sorts to the bottom.

  Ordered small → large: pistol, PDW, intermediate rifle, battle rifle,
  sniper/magnum, shotgun, then grenade-launcher / signal / special rounds
  last (matching the "grenades & flares at the bottom" decision).
  """

  # {raw_enum, display_label} in display order. The list index is the sort
  # key, so reordering this list reorders the page.
  @calibers [
    # ── Pistol ──
    {"Caliber9x18PM", "9x18mm Makarov"},
    {"Caliber9x19PARA", "9x19mm Parabellum"},
    {"Caliber9x21", "9x21mm Gyurza"},
    {"Caliber762x25TT", "7.62x25mm Tokarev"},
    {"Caliber1143x23ACP", ".45 ACP"},
    {"Caliber9x33R", ".357 Magnum"},
    # ── PDW ──
    {"Caliber46x30", "4.6x30mm"},
    {"Caliber57x28", "5.7x28mm"},
    # ── Intermediate rifle ──
    {"Caliber366TKM", ".366 TKM"},
    {"Caliber762x35", ".300 Blackout"},
    {"Caliber545x39", "5.45x39mm"},
    {"Caliber556x45NATO", "5.56x45mm NATO"},
    {"Caliber762x39", "7.62x39mm"},
    # ── Battle rifle ──
    {"Caliber68x51", "6.8x51mm (.277 Fury)"},
    {"Caliber762x51", "7.62x51mm NATO"},
    {"Caliber762x54R", "7.62x54mmR"},
    # ── Sniper / magnum / heavy ──
    {"Caliber86x70", ".338 Lapua Magnum"},
    {"Caliber93x64", "9.3x64mm"},
    {"Caliber127x33", "12.7x33mm"},
    {"Caliber127x55", "12.7x55mm STs-130"},
    {"Caliber127x99", "12.7x99mm NATO"},
    # ── Shotgun ──
    {"Caliber12g", "12/70"},
    {"Caliber20g", "20/70"},
    {"Caliber23x75", "23x75mm"},
    # ── Grenade launcher / signal / special (bottom) ──
    {"Caliber40x46", "40x46mm"},
    {"Caliber40mmRU", "40mm VOG"},
    {"Caliber26x75", "26x75mm (Signal)"},
    {"Caliber20x1mm", "20x1mm"},
    {"Caliber784x49", "7.84x49mm"}
  ]

  @labels Map.new(@calibers)
  @order @calibers |> Enum.with_index() |> Map.new(fn {{enum, _label}, i} -> {enum, i} end)
  # Unknown calibers sort after every known one (then alphabetically by
  # their fallback label, applied by the caller).
  @unknown_order length(@calibers)

  @doc """
  Human display label for a raw caliber enum. Falls back to stripping the
  `"Caliber"` prefix (e.g. an unmapped `"CaliberX"` → `"X"`) so a new
  patch caliber still renders something readable instead of the raw enum.
  """
  @spec label(String.t() | nil) :: String.t()
  def label(caliber) when is_binary(caliber) do
    Map.get(@labels, caliber) || fallback_label(caliber)
  end

  def label(_), do: "Unknown"

  @doc """
  Sort key for a raw caliber enum — its position in the curated display
  order. Unmapped calibers all share a single key that sorts *after* every
  known caliber, so they cluster at the bottom (break ties on the label).
  """
  @spec order(String.t() | nil) :: non_neg_integer()
  def order(caliber) when is_binary(caliber), do: Map.get(@order, caliber, @unknown_order)
  def order(_), do: @unknown_order

  @doc "Whether we have an explicit label/order for this caliber enum."
  @spec known?(String.t() | nil) :: boolean()
  def known?(caliber) when is_binary(caliber), do: Map.has_key?(@labels, caliber)
  def known?(_), do: false

  # Strip the "Caliber" prefix for an unmapped enum; if it doesn't have
  # that prefix, return it unchanged. Never raises.
  defp fallback_label("Caliber" <> rest) when rest != "", do: rest
  defp fallback_label(other), do: other
end
