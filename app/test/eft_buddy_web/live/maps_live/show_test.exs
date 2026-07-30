defmodule EftBuddyWeb.MapsLive.ShowTest do
  @moduledoc """
  View-level helpers that stayed on the LiveView.

  Boss grouping, escort cards and the chance / trigger labels moved to
  `EftBuddy.Maps.Bosses` (and are covered by `EftBuddy.Maps.BossesTest`) so the
  index and detail pages share one implementation.
  """
  use ExUnit.Case, async: true

  alias EftBuddyWeb.MapsLive.Show

  describe "labels" do
    test "spawn times render as m:ss" do
      assert Show.spawn_time_label(0) == "0:00"
      assert Show.spawn_time_label(950) == "15:50"
      assert Show.spawn_time_label(-1) == nil
    end

    test "night-restricted spawns get a moon" do
      assert Show.spawn_trigger_icon("Night only") == "hero-moon"
    end

    test "everything else gets the bolt" do
      assert Show.spawn_trigger_icon("autoId_00000_D2_LEVER") == "hero-bolt"
      assert Show.spawn_trigger_icon(nil) == "hero-bolt"
    end
  end

  describe "raid_variants/1" do
    test "a single-variant map shows no variant chips" do
      assert Show.raid_variants(%{variants: [%{base: true}]}) == []
    end

    test "a multi-variant map lists the base first" do
      night = %{base: false, kind: "night", label: "Night"}
      day = %{base: true, kind: "base", label: "Day"}

      assert Enum.map(Show.raid_variants(%{variants: [night, day]}), & &1.label) ==
               ["Day", "Night"]
    end
  end
end
