defmodule EftBuddy.Sync.ReporterStatusTest do
  @moduledoc """
  What `Reporter` records about a run, as opposed to what it logs.

  This is the input `EftBuddy.Sync.Freshness` reasons over, so the distinctions it
  draws here are the ones the readiness probe can and cannot see. In particular a
  run that DECLINED to do its work has to be distinguishable from one that did it —
  before `:skipped` existed, `{:skip, _}` fell through to `:done` and Freshness,
  which only looked for `:error`, read it as healthy.
  """
  # Deliberately NOT async. The status table is global, named and public — the one
  # piece of cross-test shared state in the app. `EftBuddyWeb.LoadState` reads it,
  # so an `:error` recorded here turns an unrelated LiveView's standby panel into a
  # fault marker, and `/health/sync` answers 503. See `Reporter.reset_status/0`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Sync.Reporter

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  # `with_run/2` logs a start line and a summary line on every call; none of these
  # tests are about the log, so it is swallowed rather than asserted on.
  defp record(label, result) do
    capture_log(fn -> Reporter.with_run(label, fn -> result end) end)
    Map.fetch!(Reporter.status(), label)
  end

  # Force the wall clock to advance between two recorded runs.
  #
  # Not a wait for anything — `record/2` is synchronous and its write has already
  # landed. Two runs in a row complete well inside one clock tick on Windows, which
  # made `at` and `last_ok_at` compare equal and let the ordering assertions below
  # pass whether or not the field was being carried forward correctly.
  defp tick, do: Process.sleep(20)

  describe "outcome" do
    test "a run that declined to do its work records :skipped, not :done" do
      # `{:skip, _}` is what `sync_barters/1` returns when the traders it needs are
      # not in the database yet. Recording it as `:done` — which is what the
      # catch-all did — makes it indistinguishable from a successful run to
      # everything downstream.
      assert record("ProbeSync", {:skip, "no resolvable barters"}).outcome == :skipped
    end

    test "success, failure and an unrecognised return still map as before" do
      assert record("ProbeSync", {:ok, %{items: 1}}).outcome == :ok
      assert record("ProbeSync", :ok).outcome == :ok
      assert record("ProbeSync", {:error, :boom}).outcome == :error
      assert record("ProbeSync", :something_else).outcome == :done
    end
  end

  describe "last_ok_at" do
    test "a successful run is its own last success" do
      status = record("ProbeSync", {:ok, %{}})

      assert status.last_ok_at == status.at
    end

    test "a run that never succeeded has no last success rather than a recent one" do
      # `nil`, not `at`. If a failing run could stamp its own `at` here, a feed that
      # failed every single time would age from its most recent failure and read as
      # perpetually fresh — the exact inversion this field exists to prevent.
      assert record("ProbeSync", {:error, :boom}).last_ok_at == nil
      assert record("ProbeSync", {:skip, "nothing to do"}).last_ok_at == nil
    end

    test "a later failure preserves the timestamp of the last success" do
      # The whole point. `at` advances on every tick; `last_ok_at` stands still until
      # the feed actually works again, which is what lets Freshness age a
      # ticking-but-idle feed out on its budget.
      succeeded = record("ProbeSync", {:ok, %{}})
      tick()
      then_skipped = record("ProbeSync", {:skip, "dependency not ready"})

      assert then_skipped.outcome == :skipped
      assert then_skipped.last_ok_at == succeeded.at

      assert DateTime.compare(then_skipped.at, then_skipped.last_ok_at) == :gt,
             "the run is more recent than the success it is still reporting"
    end

    test "a success after a failure moves it forward again" do
      first = record("ProbeSync", {:ok, %{}})
      tick()
      record("ProbeSync", {:error, :boom})
      tick()
      recovered = record("ProbeSync", {:ok, %{}})

      assert DateTime.compare(recovered.last_ok_at, first.at) == :gt,
             "recovery must re-stamp, not leave the stale success in place"

      assert recovered.last_ok_at == recovered.at
    end
  end

  describe "consecutive_skips" do
    test "counts a run of skips and resets on any other outcome" do
      # "skipped once on a cold start" and "has skipped forty times in a row" are
      # otherwise the same record, and only the second is worth waking up for.
      assert record("ProbeSync", {:skip, "a"}).consecutive_skips == 1
      assert record("ProbeSync", {:skip, "b"}).consecutive_skips == 2
      assert record("ProbeSync", {:ok, %{}}).consecutive_skips == 0
      assert record("ProbeSync", {:skip, "c"}).consecutive_skips == 1
      assert record("ProbeSync", {:error, :boom}).consecutive_skips == 0
    end

    test "is tracked per label, not globally" do
      record("ProbeSync", {:skip, "a"})
      record("OtherSync", {:skip, "a"})

      assert Reporter.status()["ProbeSync"].consecutive_skips == 1
      assert Reporter.status()["OtherSync"].consecutive_skips == 1
    end
  end

  describe "the telemetry a run emits" do
    test "carries the skipped outcome so a handler can see it too" do
      # `[:eft_buddy, :sync, :stop]` drives cache invalidation and warming, both of
      # which key on `label` rather than `outcome` — but the metadata is the only
      # place a future handler could distinguish a skip, so it must not be flattened.
      :telemetry.attach(
        {__MODULE__, :probe},
        [:eft_buddy, :sync, :stop],
        fn _event, _measurements, meta, pid -> send(pid, {:stop, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :probe}) end)

      capture_log(fn -> Reporter.with_run("ProbeSync", fn -> {:skip, "nope"} end) end)

      assert_receive {:stop, %{label: "ProbeSync", outcome: :skipped}}
    end
  end
end
