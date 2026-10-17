defmodule EftBuddy.Items.SyncRetryTest do
  @moduledoc """
  A failed Items cold start used to wait out the full twelve hours (audit H6):
  `Items.Sync` is hand-rolled, so it never got the scheduler's short fallback,
  and its barter/craft step returned `{:ok, _}` whatever happened inside, so
  Bootstrap released it a full interval out with an empty table.

  These drive the real GenServer with tarkov.dev answering 503.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Items.Sync
  alias EftBuddy.Sync.{Reporter, Scheduler}

  @hour 60 * 60 * 1_000

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  defp upstream_down do
    Req.Test.stub(EftBuddy.TarkovApi, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
  end

  defp start_feed do
    pid = start_supervised!(%{id: :items_sync_probe, start: {GenServer, :start_link, [Sync, []]}})
    Req.Test.allow(EftBuddy.TarkovApi, self(), pid)
    pid
  end

  defp full_delay, do: Reporter.schedule()["ItemsSync"].delay_ms

  defp full_tick(pid) do
    capture_log(fn ->
      send(pid, :full_sync)
      :sys.get_state(pid)
    end)

    {:sys.get_state(pid), full_delay()}
  end

  describe "the barter and craft step" do
    test "is a failure when its sub-steps write nothing, naming each one" do
      # No items, traders or station levels: every barter and craft is
      # unresolvable, so each sub-step skips. That used to come back `{:ok, _}`.
      upstream_down()

      result = capture_log(fn -> send(self(), {:r, Sync.run_barters_and_crafts()}) end)
      assert result =~ "Barters"
      assert_received {:r, {:error, {:partial, succeeded, failed}}}

      assert succeeded == []

      assert failed |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ~w(barters:pve barters:regular crafts)
    end

    test "describes a skipped sub-step readably" do
      text = Reporter.describe_error({:partial, [], [{"crafts", {:skipped, "no recipes"}}]})
      assert text == "crafts failed (skipped: no recipes)"
    end
  end

  describe "the GenServer" do
    setup do
      upstream_down()
      :ok
    end

    test "boots with a 15-minute full-tick fallback, not the 12-hour interval" do
      start_feed()

      assert full_delay() >= Scheduler.default_fallback_ms()
      assert full_delay() <= Scheduler.default_fallback_ms() + Scheduler.max_jitter_ms() + 1
    end

    test "a failed cold start arms the retry in 15 minutes" do
      pid = start_feed()

      GenServer.cast(pid, :bootstrap_failed)
      state = :sys.get_state(pid)

      assert state.retrying?
      assert full_delay() <= Scheduler.failure_retry_ms() + Scheduler.max_jitter_ms() + 1
    end

    test "a successful cold start still anchors a full interval plus stagger out" do
      pid = start_feed()

      GenServer.cast(pid, :bootstrap_complete)
      :sys.get_state(pid)

      assert full_delay() >= Sync.full_interval_ms() + Sync.stagger_ms()
    end

    test "a failed full tick retries once in 15 minutes, then goes back to 12 hours" do
      pid = start_feed()

      {state, delay} = full_tick(pid)
      assert state.retrying?
      assert delay <= Scheduler.failure_retry_ms() + Scheduler.max_jitter_ms() + 1

      {state, delay} = full_tick(pid)
      refute state.retrying?
      assert delay >= 12 * @hour
    end

    test "the run happens outside the GenServer" do
      pid = start_feed()
      test = self()

      :telemetry.attach(
        {__MODULE__, :runner},
        [:eft_buddy, :sync, :stop],
        fn
          _e, _m, %{label: "ItemsSync"}, _ -> send(test, {:ran_in, self()})
          _e, _m, _meta, _ -> :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :runner}) end)

      full_tick(pid)

      assert_received {:ran_in, runner}
      assert runner != pid
      refute Process.alive?(runner)
    end
  end
end
