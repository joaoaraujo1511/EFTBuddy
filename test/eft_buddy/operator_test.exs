defmodule EftBuddy.OperatorTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Operator

  describe "parse/2 guards every untrusted boundary" do
    test "clamps the PMC level into the legal range" do
      assert Operator.parse(:pmc_level, 0) == Operator.min_level()
      assert Operator.parse(:pmc_level, 999) == Operator.max_level()
      assert Operator.parse(:pmc_level, 42) == 42
    end

    test "accepts a typed level as a string (the HUD's number field)" do
      assert Operator.parse(:pmc_level, "17") == 17
      assert Operator.parse(:pmc_level, " 17 ") == 17
    end

    test "returns nil for a missing or junk value so callers keep the current one" do
      for value <- [nil, "", "abc", %{}, [], true] do
        assert Operator.parse(:pmc_level, value) == nil
      end

      assert Operator.parse(:mode, "sandbox") == nil
      assert Operator.parse(:faction, "raiders") == nil
      assert Operator.parse(:scav_karma, "not-a-number") == nil
      assert Operator.parse(:rail_collapsed, "yes") == nil
    end

    test "normalises mode and faction from both strings and atoms" do
      assert Operator.parse(:mode, "pve") == :pve
      assert Operator.parse(:mode, :pve) == :pve
      assert Operator.parse(:faction, "bear") == :bear
      assert Operator.parse(:faction, :bear) == :bear
    end
  end

  describe "scav karma is stored in integer hundredths" do
    test "converts whole and fractional karma from JSON numbers" do
      # JSON.stringify(0.0) emits `0`, so integers arrive meaning whole units.
      assert Operator.parse(:scav_karma, 3) == 300
      assert Operator.parse(:scav_karma, -1.4) == -140
      assert Operator.parse(:scav_karma, "0.25") == 25
    end

    test "clamps to the in-game range" do
      assert Operator.parse(:scav_karma, 99) == 600
      assert Operator.parse(:scav_karma, -99) == -600
    end

    test "repeated stepping does not accumulate float drift" do
      # The whole reason karma is integral internally: doing this with floats
      # yields 0.30000000000000004 and renders as a jittering HUD value.
      cents =
        Enum.reduce(1..3, 0, fn _i, acc -> Operator.step_karma(acc, :up) end)

      assert cents == 30
      assert Operator.karma_to_float(cents) === 0.3

      # A full sweep down and back up must land exactly on zero.
      down = Enum.reduce(1..60, 0, fn _i, acc -> Operator.step_karma(acc, :down) end)
      assert down == -600
      assert Operator.karma_to_float(down) === -6.0

      back = Enum.reduce(1..60, down, fn _i, acc -> Operator.step_karma(acc, :up) end)
      assert back == 0
      assert Operator.karma_to_float(back) === 0.0
    end

    test "stepping saturates at the bounds rather than overflowing" do
      assert Operator.step_karma(600, :up) == 600
      assert Operator.step_karma(-600, :down) == -600
    end
  end

  describe "parse_all/1" do
    test "accepts the cookie's nested string keys and drops unknown or invalid entries" do
      parsed =
        Operator.parse_all(%{
          "mode" => "pve",
          "evil_key" => "payload",
          "modes" => %{
            "pvp" => %{"pmc_level" => 30, "scav_karma" => 1.5},
            "pve" => %{"pmc_level" => 7, "faction" => "bogus", "evil_key" => "payload"}
          }
        })

      assert parsed.mode == :pve
      refute Map.has_key?(parsed, :evil_key)

      assert Operator.mode_slice(parsed, :pvp).pmc_level == 30
      assert Operator.mode_slice(parsed, :pvp).scav_karma == 150
      assert Operator.mode_slice(parsed, :pve).pmc_level == 7

      # An invalid value falls back to its default rather than vanishing, so the
      # result is always a complete pref set callers can use as-is.
      assert Operator.mode_slice(parsed, :pve).faction == :usec
      refute Map.has_key?(Operator.mode_slice(parsed, :pve), :evil_key)
    end

    test "fills in a whole missing mode rather than dropping it" do
      # The reason this returns a COMPLETE set: callers used to merge the result
      # over `defaults/0`, and now that prefs are nested a shallow merge would
      # replace the entire `:modes` map and lose the mode the cookie didn't
      # mention.
      parsed = Operator.parse_all(%{"modes" => %{"pvp" => %{"pmc_level" => 30}}})

      assert Operator.mode_slice(parsed, :pvp).pmc_level == 30
      assert Operator.mode_slice(parsed, :pve) == Operator.mode_slice(Operator.defaults(), :pve)
    end

    test "tolerates a non-map (corrupt cookie)" do
      assert Operator.parse_all("garbage") == Operator.defaults()
      assert Operator.parse_all(nil) == Operator.defaults()
    end
  end

  describe "per-mode prefs" do
    test "active/1 flattens the global prefs and the ACTIVE mode's slice" do
      prefs =
        Operator.parse_all(%{
          "mode" => "pve",
          "rail_collapsed" => true,
          "modes" => %{
            "pvp" => %{"pmc_level" => 40, "faction" => "usec"},
            "pve" => %{"pmc_level" => 3, "faction" => "bear"}
          }
        })

      # This flattening is what lets the HUD and every page keep reading a plain
      # `@pmc_level` while the value is stored per mode.
      assert Operator.active(prefs) == %{
               mode: :pve,
               rail_collapsed: true,
               pmc_level: 3,
               scav_karma: 0,
               faction: :bear
             }
    end

    test "writing a per-mode pref leaves the other mode untouched" do
      # The whole point of the split: PVP and PVE are separate progressions.
      prefs = Operator.defaults()

      prefs = Operator.put_pref(prefs, :pmc_level, 42)
      prefs = Operator.put_pref(prefs, :faction, :bear)

      assert Operator.mode_slice(prefs, :pvp).pmc_level == 42
      assert Operator.mode_slice(prefs, :pvp).faction == :bear
      assert Operator.mode_slice(prefs, :pve) == Operator.mode_slice(Operator.defaults(), :pve)
    end

    test "flipping mode swaps which slice reads and writes are routed to" do
      prefs =
        Operator.defaults()
        |> Operator.put_pref(:pmc_level, 42)
        |> Operator.put_pref(:mode, :pve)

      # Same key, different mode: the PVE profile is still at its default.
      assert Operator.get_pref(prefs, :pmc_level) == Operator.min_level()

      prefs = Operator.put_pref(prefs, :pmc_level, 9)
      assert Operator.get_pref(prefs, :pmc_level) == 9

      # ...and switching back finds the PVP value exactly as it was left.
      prefs = Operator.put_pref(prefs, :mode, :pvp)
      assert Operator.get_pref(prefs, :pmc_level) == 42
    end

    test "a global pref is shared by both modes" do
      prefs = Operator.put_pref(Operator.defaults(), :rail_collapsed, true)

      assert Operator.get_pref(prefs, :rail_collapsed) == true
      assert Operator.active(Operator.put_pref(prefs, :mode, :pve)).rail_collapsed == true
    end

    test "cookie_payload/1 round-trips through parse_all/1 unchanged" do
      # The cookie is the durable cold-boot record, so this round-trip is what
      # makes a reload (or a deploy) hand back exactly what the operator had.
      # Karma is the trap: it is integer hundredths internally but karma units on
      # the way in, so a payload that skipped `cookie_value/2` would come back
      # multiplied by 100.
      prefs =
        Operator.defaults()
        |> Operator.put_pref(:pmc_level, 40)
        |> Operator.put_pref(:scav_karma, 250)
        |> Operator.put_pref(:mode, :pve)
        |> Operator.put_pref(:pmc_level, 6)
        |> Operator.put_pref(:faction, :bear)

      assert prefs |> Operator.cookie_payload() |> Operator.parse_all() == prefs
    end

    test "cookie_payload/1 emits JSON-safe values for both modes" do
      payload = Operator.cookie_payload(Operator.defaults())

      assert payload["mode"] == "pvp"
      assert payload["rail_collapsed"] == false

      for mode <- ["pvp", "pve"] do
        assert payload["modes"][mode] == %{
                 "pmc_level" => 1,
                 "scav_karma" => 0.0,
                 "faction" => "usec"
               }
      end
    end
  end

  describe "cookie_value/2" do
    test "emits JSON-safe values for the browser's durable copy" do
      assert Operator.cookie_value(:mode, :pve) == "pve"
      assert Operator.cookie_value(:faction, :usec) == "usec"
      assert Operator.cookie_value(:scav_karma, -140) == -1.4
      assert Operator.cookie_value(:pmc_level, 12) == 12
      assert Operator.cookie_value(:rail_collapsed, true) == true
    end
  end

  test "defaults cover every declared pref key, in the right scope" do
    defaults = Operator.defaults()

    # Every pref must be either global or per-mode - never both, never neither -
    # or `active/1` would silently drop it.
    assert Enum.sort(Operator.global_pref_keys() ++ Operator.mode_pref_keys()) ==
             Enum.sort(Operator.pref_keys())

    for key <- Operator.global_pref_keys() do
      assert Map.has_key?(defaults, key), "missing global default for #{key}"
    end

    for mode <- Operator.game_modes(), key <- Operator.mode_pref_keys() do
      assert Map.has_key?(Operator.mode_slice(defaults, mode), key),
             "missing #{mode} default for #{key}"
    end

    for key <- Operator.pref_keys() do
      assert Map.has_key?(Operator.active(defaults), key), "#{key} missing from active/1"
    end
  end
end
