defmodule EftBuddy.Maps.Bosses do
  @moduledoc """
  Presentation of a map's boss roster.

  `map_bosses` holds one row per API spawn *entry*, not per boss — The Lab's
  raiders are 16 rows, Terminal's Black Division 14 — so every reader has to
  regroup them. This module is the one place that happens, so the index chips
  and the detail cards can't drift apart (they did: the index rendered 40 chips
  for Icebreaker's 5 bosses).

  Escorts stay attached to the boss they serve, as chips on its card
  (`merged_escorts/1`). They deliberately get no cards of their own — the
  relationship only needs to read one way, and a dedicated boss view is coming.
  """

  @doc """
  Bosses grouped into one card per identity, each carrying its spawn entries.

  Grouped on `{normalized_name, name}` rather than `external_id`, because a
  single display name can cover several mob ids — Terminal's "AF" is `vsRF`,
  `vsRFSniper` and `Sentry`, which previously rendered as duplicate cards.

  Rows are ordered by first appearance, which `EftBuddy.Maps` pins with an
  explicit `order_by` on the preload so the API's own ordering (which puts a
  map's headline boss first) actually survives.
  """
  def group(bosses) do
    grouped = Enum.group_by(bosses, &{&1.normalized_name, &1.name})

    bosses
    |> Enum.map(&{&1.normalized_name, &1.name})
    |> Enum.uniq()
    |> Enum.map(fn key -> build_group(key, Map.fetch!(grouped, key)) end)
  end

  defp build_group({slug, name}, entries) do
    %{
      normalized_name: slug,
      name: name,
      image_portrait_link: Enum.find_value(entries, & &1.image_portrait_link),
      chance_label: chance_label(entries),
      rows: entry_rows(entries),
      escorts: merged_escorts(entries)
    }
  end

  @doc """
  Escort label with its count when the API gives one, e.g. `"Rogue x3"`.

  `amount` is a list of `{count, chance}` alternatives; we show the largest
  count, which is the "full squad" case players care about.
  """
  def escort_label(escort) do
    case escort_count(escort) do
      count when count > 1 -> "#{escort["name"]} x#{count}"
      _ -> escort["name"]
    end
  end

  defp escort_count(escort) do
    (escort["amount"] || [])
    |> Enum.map(& &1["count"])
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 1 end)
  end

  @doc "Render a 0.0-1.0 chance as a whole-percent label, or a dash."
  def percent_label(chance) when is_float(chance), do: "#{round(chance * 100)}%"
  def percent_label(chance) when is_integer(chance), do: "#{round(chance * 100)}%"
  def percent_label(_), do: "-"

  @doc """
  Human label for a raw `spawn_trigger`.

  The API leaks internal ids for lever-activated spawns
  (`autoId_00000_D2_LEVER` on Reserve), which are meaningless to a player, so
  those are normalised to "Switch".
  """
  def trigger_label(trigger) when is_binary(trigger) do
    if switch_trigger?(trigger), do: "Switch", else: trigger
  end

  def trigger_label(_), do: nil

  defp switch_trigger?(trigger) do
    down = String.downcase(trigger)
    String.contains?(down, "switch") or String.contains?(down, "lever")
  end

  # A boss's spawn entries, collapsed only where they genuinely agree.
  #
  # Keyed on `{variant, chance, trigger}`, merging the spawn times and zones of
  # everything that matches. That keeps every distinct number visible while
  # staying readable: Terminal's Black Division has 14 entries that differ only
  # by wave time, so they become one row listing 14 times, and The Lab's 16
  # raider entries collapse to the handful of real (chance, trigger) pairs
  # instead of 16 near-identical lines.
  defp entry_rows(entries) do
    entries
    # Grouped on the *displayed* trigger, not the raw one: Reserve's raiders
    # carry both "Switch" and "autoId_00000_D2_LEVER", which mean the same thing
    # to a player and would otherwise render as two identical rows.
    |> Enum.group_by(fn b ->
      {variant_label(b), b.spawn_chance, trigger_label(b.spawn_trigger)}
    end)
    |> Enum.map(fn {{label, chance, trigger}, group} ->
      %{
        variant_label: label,
        chance: chance,
        trigger: trigger,
        times: spawn_times(group),
        # Deduped on the *display* name, unlike the marker join, which uses the
        # raw `spawn_key`: these are the zone chips on the card, and listing
        # "Dorms" twice because two raw keys translate alike would read as a bug.
        locations: Enum.uniq_by(Enum.flat_map(group, &(&1.spawn_locations || [])), & &1["name"])
      }
    end)
    |> Enum.sort_by(fn r -> {r.variant_label || "", -(r.chance || 0.0)} end)
  end

  defp variant_label(%{variant: %{label: label}}) when is_binary(label), do: label
  defp variant_label(_), do: nil

  # Scripted wave times, ascending. `-1` means "no timer", which is the common
  # case and carries no information, so it's dropped.
  defp spawn_times(entries) do
    entries
    |> Enum.map(& &1.spawn_time)
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A single chance when every entry agrees, else the range. Factory's Tagilla
  # is 50% by day and 75% at night, and reporting only the first was wrong.
  defp chance_label(entries) do
    case entries |> Enum.map(& &1.spawn_chance) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> "-"
      [only] -> percent_label(only)
      many -> "#{percent_label(Enum.min(many))}-#{percent_label(Enum.max(many))}"
    end
  end

  # Escorts across every entry, deduped. The API repeats a boss's escort list on
  # each of its entries, and Terminal's Black Division even lists the same
  # escort twice within one entry.
  defp merged_escorts(entries) do
    entries
    |> Enum.flat_map(&(&1.escorts || []))
    |> Enum.uniq_by(fn e -> e["normalized_name"] || e["name"] end)
    |> Enum.reject(&is_nil(&1["name"]))
  end
end
