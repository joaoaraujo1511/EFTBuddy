defmodule EftBuddy.Wiki.DumpScriptTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Wiki.DumpScript

  describe "throttle/1" do
    test "does not sleep on the first call of a fresh process" do
      # Run in a fresh process so :last_request_at isn't already set.
      task =
        Task.async(fn ->
          {elapsed, _} = :timer.tc(fn -> DumpScript.throttle(10_000) end)
          elapsed
        end)

      elapsed_us = Task.await(task, 15_000)
      # First call must not pay the throttle (off-by-one fix). A ten-second
      # throttle against a five-second bound: a sleep cannot pass, and a loaded
      # machine cannot fail it. It was 250ms against 100ms, which flaked.
      assert elapsed_us < 5_000_000
    end
  end
end
