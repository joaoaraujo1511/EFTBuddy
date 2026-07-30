defmodule EftBuddy.Wiki.DumpScriptTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Wiki.DumpScript

  describe "parse_args/2" do
    test "parses --key value flags and positionals" do
      assert DumpScript.parse_args(["--output", "/tmp/x", "extra"]) ==
               {[output: "/tmp/x"], ["extra"]}
    end

    test "treats a bare --flag (followed by another flag) as boolean true" do
      assert DumpScript.parse_args(["--dry-run", "--quest", "Golden Swag"]) ==
               {[dry_run: true, quest: "Golden Swag"], []}
    end

    test "a trailing --flag is boolean true" do
      assert DumpScript.parse_args(["--dry-run"]) == {[dry_run: true], []}
    end

    test "dashes in keys become underscores" do
      assert DumpScript.parse_args(["--no-color", "x"]) == {[no_color: "x"], []}
    end

    test "casts integer_keys to integers, leaves others as strings" do
      assert DumpScript.parse_args(["--limit", "5", "--quest", "Q"], [:limit]) ==
               {[limit: 5, quest: "Q"], []}
    end

    test "non-integer keys are not cast even when numeric" do
      assert DumpScript.parse_args(["--output", "5"]) == {[output: "5"], []}
    end
  end

  describe "throttle/1" do
    test "does not sleep on the first call of a fresh process" do
      # Run in a fresh process so :last_request_at isn't already set.
      task =
        Task.async(fn ->
          {elapsed, _} = :timer.tc(fn -> DumpScript.throttle(250) end)
          elapsed
        end)

      elapsed_us = Task.await(task)
      # First call must not pay the full 250ms throttle (off-by-one fix).
      assert elapsed_us < 100_000
    end
  end
end
