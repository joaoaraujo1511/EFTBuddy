defmodule EftBuddy.Maps.BossesTest do
  @moduledoc """
  Regression tests for the boss panel. Each case pins a number that was
  previously rendered wrong because every one of a boss's spawn entries but the
  first was discarded.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Maps.Bosses

  defp boss(attrs) do
    Map.merge(
      %{
        name: "Boss",
        normalized_name: "boss",
        image_portrait_link: nil,
        spawn_chance: 0.5,
        spawn_trigger: nil,
        spawn_time: -1,
        spawn_locations: [],
        escorts: [],
        variant: nil
      },
      attrs
    )
  end

  defp zone(name), do: %{"spawn_key" => name, "name" => name, "chance" => 1.0, "positions" => []}

  describe "group/1 — one card per identity" do
    # Terminal's "AF" is three distinct mob ids (vsRF, vsRFSniper, Sentry).
    # Grouping by external_id rendered it as duplicate identical cards.
    test "different mob ids sharing a display name collapse into one card" do
      groups =
        Bosses.group([
          boss(%{external_id: "vsRF", name: "AF", normalized_name: "af"}),
          boss(%{external_id: "vsRFSniper", name: "AF", normalized_name: "af"}),
          boss(%{external_id: "Sentry", name: "AF", normalized_name: "af"})
        ])

      assert [%{name: "AF"}] = groups
    end

    test "distinct bosses stay separate and keep first-seen order" do
      groups =
        Bosses.group([
          boss(%{name: "Reshala", normalized_name: "reshala"}),
          boss(%{name: "Knight", normalized_name: "knight"}),
          boss(%{name: "Reshala", normalized_name: "reshala"})
        ])

      assert Enum.map(groups, & &1.name) == ["Reshala", "Knight"]
    end

    # The index card used to iterate `map.bosses` raw, so Icebreaker's 40 spawn
    # entries rendered as 40 chips for its 5 bosses.
    test "many entries of one boss produce a single chip" do
      entries = for i <- 1..16, do: boss(%{name: "Raider", spawn_time: i})
      assert length(Bosses.group(entries)) == 1
    end
  end

  describe "chance_label — ranges instead of the first entry" do
    # Lighthouse's rogues run 20%, 50% and 80% across seven zones. The card used
    # to read a flat "80%", which was false for four of them.
    test "a boss with varying chances reports the range" do
      [group] =
        Bosses.group([
          boss(%{name: "Rogue", spawn_chance: 0.8}),
          boss(%{name: "Rogue", spawn_chance: 0.5}),
          boss(%{name: "Rogue", spawn_chance: 0.2})
        ])

      assert group.chance_label == "20%-80%"
    end

    test "a boss with one consistent chance reports a single figure" do
      [group] = Bosses.group([boss(%{spawn_chance: 0.75})])
      assert group.chance_label == "75%"
    end

    test "a boss with no chance data reports a dash" do
      [group] = Bosses.group([boss(%{spawn_chance: nil})])
      assert group.chance_label == "-"
    end
  end

  describe "entry rows" do
    # Factory's Tagilla is 50% by day and 75% at night. Both must survive,
    # attributed to their variant.
    test "the same boss in two variants keeps both chances" do
      [group] =
        Bosses.group([
          boss(%{name: "Tagilla", spawn_chance: 0.5, variant: %{label: "Day", kind: "base"}}),
          boss(%{name: "Tagilla", spawn_chance: 0.75, variant: %{label: "Night", kind: "night"}})
        ])

      assert group.chance_label == "50%-75%"

      assert Enum.sort(Enum.map(group.rows, &{&1.variant_label, &1.chance})) ==
               [{"Day", 0.5}, {"Night", 0.75}]
    end

    # Terminal's Black Division has 14 entries that differ only by wave time.
    # They belong on one row listing every time, not 14 near-identical lines.
    test "entries differing only by spawn time merge, collecting their times" do
      [group] =
        Bosses.group([
          boss(%{spawn_chance: 1.0, spawn_time: 950}),
          boss(%{spawn_chance: 1.0, spawn_time: 1800}),
          boss(%{spawn_chance: 1.0, spawn_time: 1810})
        ])

      assert [row] = group.rows
      assert row.times == [950, 1800, 1810]
    end

    test "the no-timer sentinel is dropped rather than shown as a time" do
      [group] = Bosses.group([boss(%{spawn_time: -1})])
      assert [%{times: []}] = group.rows
    end

    # Reserve's raiders carry both "Switch" and "autoId_00000_D2_LEVER", which
    # mean the same thing to a player.
    test "triggers that display identically merge into one row" do
      [group] =
        Bosses.group([
          boss(%{spawn_chance: 0.3, spawn_trigger: "Switch"}),
          boss(%{spawn_chance: 0.3, spawn_trigger: "autoId_00000_D2_LEVER"})
        ])

      assert [%{trigger: "Switch"}] = group.rows
    end

    test "genuinely different triggers stay on separate rows" do
      [group] =
        Bosses.group([
          boss(%{spawn_chance: 0.4, spawn_trigger: nil}),
          boss(%{spawn_chance: 0.3, spawn_trigger: "Switch"})
        ])

      assert length(group.rows) == 2
    end

    test "zones are merged across entries and deduped by name" do
      [group] =
        Bosses.group([
          boss(%{spawn_chance: 0.6, spawn_locations: [zone("First Floor")]}),
          boss(%{spawn_chance: 0.6, spawn_locations: [zone("First Floor"), zone("Basement")]})
        ])

      assert [row] = group.rows
      assert Enum.map(row.locations, & &1["name"]) == ["First Floor", "Basement"]
    end
  end

  describe "escorts" do
    test "deduped across entries, which repeat the same escort list" do
      [group] =
        Bosses.group([
          boss(%{escorts: [%{"name" => "Raider", "normalized_name" => "raider"}]}),
          boss(%{escorts: [%{"name" => "Raider", "normalized_name" => "raider"}]})
        ])

      assert length(group.escorts) == 1
    end

    test "counts are surfaced, not dropped" do
      escort = %{"name" => "Rogue", "normalized_name" => "rogue", "amount" => [%{"count" => 3}]}
      assert Bosses.escort_label(escort) == "Rogue x3"
    end

    test "a single escort needs no multiplier" do
      escort = %{"name" => "Birdeye", "amount" => [%{"count" => 1}]}
      assert Bosses.escort_label(escort) == "Birdeye"
    end

    test "an escort with no count falls back to its bare name" do
      assert Bosses.escort_label(%{"name" => "Big Pipe"}) == "Big Pipe"
    end
  end

  describe "labels" do
    test "internal lever ids are normalised for display" do
      assert Bosses.trigger_label("autoId_00000_D2_LEVER") == "Switch"
      assert Bosses.trigger_label("Switch") == "Switch"
      assert Bosses.trigger_label(nil) == nil
    end

    test "percent labels round to whole percent" do
      assert Bosses.percent_label(0.335) == "34%"
      assert Bosses.percent_label(nil) == "-"
    end
  end
end
