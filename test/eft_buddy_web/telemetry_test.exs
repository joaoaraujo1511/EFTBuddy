defmodule EftBuddyWeb.TelemetryTest do
  @moduledoc """
  Pins the metric definitions against the events that actually fire.

  ~15 metrics were defined and **none** were consumed for the project's whole life:
  the generator's reporter line sat commented out, so `metrics/0` was decorative.
  The failure mode a test can catch is the other half of that — a metric whose event
  name, measurement key or tag does not match what the code emits is silently dead
  too, and looks identical to a working one on the page.
  """
  use ExUnit.Case, async: false

  alias EftBuddy.OperatorSessions
  alias EftBuddy.Progress
  alias EftBuddy.Sync.Helpers
  alias EftBuddy.Sync.Reporter
  alias EftBuddyWeb.Telemetry

  # `Reporter`'s status table is global and named, and `EftBuddyWeb.LoadState` reads
  # it — so a run recorded here would change what unrelated LiveViews render. Reset
  # on the way in and the way out.
  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  # Every metric this module defines, as {event_name, measurement_key}. Read off the
  # `Telemetry.Metrics` structs rather than parsed out of the dotted string, so the
  # test asks the same question the reporter does.
  defp declared do
    for m <- Telemetry.metrics(), is_atom(m.measurement), do: {m.event_name, m.measurement}
  end

  defp declared_for(event), do: for({^event, key} <- declared(), do: key)

  # Capture one telemetry event and hand back {measurements, metadata}.
  defp capture(event, fun) do
    test = self()
    ref = make_ref()
    handler = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      event,
      fn _e, measurements, metadata, _cfg ->
        send(test, {ref, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()

      receive do
        {^ref, measurements, metadata} -> {measurements, metadata}
      after
        500 -> flunk("no #{inspect(event)} event was emitted")
      end
    after
      :telemetry.detach(handler)
    end
  end

  describe "the app-specific metrics match the events the code emits" do
    test "sync freshness: one gauge per label, tagged by label and outcome" do
      Reporter.attach_telemetry()
      # Give the status table something to report on.
      Reporter.with_run("TelemetryTestSync", fn -> :ok end)

      {measurements, metadata} =
        capture([:eft_buddy, :sync, :freshness], &Reporter.emit_freshness/0)

      for key <- declared_for([:eft_buddy, :sync, :freshness]) do
        assert Map.has_key?(measurements, key),
               "metric declares #{key} but the event does not measure it"
      end

      # Tags must be present in METADATA, not measurements — a tag naming a
      # measurement silently produces no series.
      assert Map.has_key?(metadata, :label)
      assert Map.has_key?(metadata, :outcome)
      assert is_integer(measurements.seconds_since_run)
    end

    test "operator sessions: count and ceiling" do
      {measurements, _metadata} =
        capture([:eft_buddy, :operator_sessions], &OperatorSessions.emit_telemetry/0)

      for key <- declared_for([:eft_buddy, :operator_sessions]) do
        assert Map.has_key?(measurements, key)
      end

      assert is_integer(measurements.count)
      assert measurements.ceiling > 0
    end

    test "a refused cleanup emits, tagged by the sync that caused it" do
      # The guard receives only row counts, so attribution comes from the active
      # run's label on the process dictionary. If that wiring breaks, the metric
      # still charts but every series collapses into "unknown".
      Reporter.attach_telemetry()

      {measurements, metadata} =
        capture([:eft_buddy, :sync, :cleanup_refused], fn ->
          Reporter.with_run("GuardTestSync", fn ->
            assert {:skip, _reason} = Helpers.cleanup_safe?(100, 10)
          end)
        end)

      for key <- declared_for([:eft_buddy, :sync, :cleanup_refused]) do
        assert Map.has_key?(measurements, key)
      end

      assert metadata.label == "GuardTestSync"
      assert measurements.current_count == 100
      assert measurements.snapshot_count == 10
    end

    test "a cleanup the guard ALLOWS emits nothing" do
      # Otherwise the counter measures sync runs rather than refusals, which is the
      # kind of metric that reads as an incident every time it is correct.
      handler = "allowed-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:eft_buddy, :sync, :cleanup_refused],
        fn _e, _m, _md, _c -> send(test, :refused) end,
        nil
      )

      try do
        assert Helpers.cleanup_safe?(100, 100) == :ok
        assert Helpers.cleanup_safe?(0, 0) == :ok
        refute_receive :refused, 200
      after
        :telemetry.detach(handler)
      end
    end

    test "a rejected progress slice emits, tagged by mode" do
      oversized = %{"completed_tasks" => for(n <- 1..40_000, do: "task-slug-number-#{n}")}

      {measurements, metadata} =
        capture([:eft_buddy, :progress, :slice_rejected], fn ->
          Progress.normalize(%{"modes" => %{"pvp" => oversized}})
        end)

      for key <- declared_for([:eft_buddy, :progress, :slice_rejected]) do
        assert Map.has_key?(measurements, key)
      end

      assert metadata.mode == "pvp"
      assert measurements.bytes > measurements.ceiling
    end
  end

  describe "periodic_measurements/0" do
    test "every entry is callable and does not raise" do
      # A poller measurement that raises is dropped with a log line nobody reads, so
      # the gauge simply never appears. Call each one for real.
      for {mod, fun, args} <- Telemetry.periodic_measurements() do
        assert function_exported?(mod, fun, length(args)),
               "#{inspect(mod)}.#{fun}/#{length(args)} is not exported"

        assert apply(mod, fun, args) == :ok or true
      end
    end
  end
end
