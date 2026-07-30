defmodule EftBuddy.Sync.FreshnessTest do
  @moduledoc """
  The readiness verdict is the only thing in the system that can detect the app's
  most dangerous failure mode — a sync that stopped or truncated, after which the
  pages keep rendering and present stale game data as fact.

  Every input is injectable, so the whole decision is tested as a pure function.
  A probe whose logic can only be exercised by waiting 36 hours is a probe nobody
  ever verifies.
  """
  use ExUnit.Case, async: true

  alias EftBuddy.Sync.Freshness

  @now ~U[2026-07-30 12:00:00Z]

  defp run(label, ago_seconds, outcome \\ :ok, refusals \\ 0) do
    {label,
     %{
       outcome: outcome,
       at: DateTime.add(@now, -ago_seconds),
       duration_ms: 10,
       refusals: refusals
     }}
  end

  # A status map where every monitored family reported successfully a moment ago.
  defp all_fresh do
    Map.new(Freshness.budgets(), fn {prefix, _budget, _owner} -> run(prefix, 5) end)
  end

  defp evaluate(status, uptime \\ 100_000_000) do
    Freshness.evaluate(status: status, now: @now, uptime_seconds: uptime)
  end

  describe "a healthy node" do
    test "is ok when every family reported recently" do
      result = evaluate(all_fresh())

      assert result.status == :ok
      assert Enum.all?(result.syncs, fn {_family, f} -> f.state == :ok end)
    end

    test "reports each family's age and budget" do
      result = evaluate(Map.new([run("ItemsSync", 42)]))

      assert %{state: :ok, age_seconds: 42, budget_seconds: budget, labels: ["ItemsSync"]} =
               result.syncs["ItemsSync"]

      assert budget > 0
    end
  end

  describe "a fresh boot is not degraded" do
    test "a family that has never run is :booting while inside its budget" do
      # THE REQUIREMENT THIS EXISTS FOR. A probe that reports unhealthy for the first
      # minutes of every deploy trains its reader to ignore it, and an orchestrator
      # would refuse to bring the instance into rotation at all.
      result = evaluate(%{}, 30)

      assert result.status == :ok
      assert Enum.all?(result.syncs, fn {_family, f} -> f.state == :booting end)
      assert result.syncs["ItemsSync"].age_seconds == nil
    end

    test "but becomes :never_run once uptime exceeds the budget" do
      # The other half: a feed that never starts must eventually be reported, or
      # "booting" becomes a permanent excuse.
      %{budget_seconds: budget} = evaluate(%{}, 30).syncs["PricesSync"]

      result = evaluate(%{}, budget + 1)

      assert result.status == :degraded
      assert result.syncs["PricesSync"].state == :never_run
    end
  end

  describe "degradation" do
    test "a stale family is :stale and degrades the whole verdict" do
      %{budget_seconds: budget} = evaluate(all_fresh()).syncs["PricesSync"]

      status = all_fresh() |> Map.merge(Map.new([run("PricesSync", budget + 1)]))
      result = evaluate(status)

      assert result.status == :degraded
      assert result.syncs["PricesSync"].state == :stale
      # And nothing else was dragged down with it.
      assert result.syncs["ItemsSync"].state == :ok
    end

    test "a family inside its budget by one second is still ok" do
      %{budget_seconds: budget} = evaluate(all_fresh()).syncs["PricesSync"]

      status = all_fresh() |> Map.merge(Map.new([run("PricesSync", budget)]))

      assert evaluate(status).syncs["PricesSync"].state == :ok
    end

    test "a failed run is :failed regardless of how recent it was" do
      # Recency is not health: a sync that just ran and errored is worse than one
      # that ran an hour ago and succeeded.
      status = all_fresh() |> Map.merge(Map.new([run("HideoutSync", 1, :error)]))
      result = evaluate(status)

      assert result.status == :degraded
      assert result.syncs["HideoutSync"].state == :failed
    end

    test "a failure outranks staleness in the same family" do
      status =
        all_fresh()
        |> Map.merge(Map.new([run("TasksSync:regular", 5, :error), run("TasksSync:pve", 5)]))

      assert evaluate(status).syncs["TasksSync"].state == :failed
    end

    test "a run that REFUSED a prune is degraded even though it reported ok" do
      # The whole point. `cleanup_safe?/3` refusing a destructive prune means the
      # snapshot was implausibly small — a truncated-but-HTTP-200 upstream response —
      # so the run completed by declining to trust it. `outcome` is still `:ok`,
      # because it did complete, and until this state existed the app's single most
      # destructive failure mode announced itself as a healthy run.
      status = all_fresh() |> Map.merge(Map.new([run("ItemsSync", 5, :ok, 3)]))
      result = evaluate(status)

      assert result.status == :degraded
      assert result.syncs["ItemsSync"].state == :guard_tripped
      assert result.syncs["ItemsSync"].refusals == 3
    end

    test "refusals sum across a family's labels" do
      status =
        Map.new([run("TasksSync:regular", 5, :ok, 1), run("TasksSync:pve", 5, :ok, 2)])

      assert evaluate(status).syncs["TasksSync"].refusals == 3
    end

    test "an outright failure still outranks a refusal" do
      status = all_fresh() |> Map.merge(Map.new([run("MapsSync", 5, :error, 2)]))

      assert evaluate(status).syncs["MapsSync"].state == :failed
    end

    test "a record predating the refusals field is treated as zero, not as missing data" do
      # Records written before `refusals` existed must not crash the probe or read as
      # suspicious — an absent field means "we did not measure", and the safe reading
      # of that is zero.
      legacy = %{"AmmoSync" => %{outcome: :ok, at: @now, duration_ms: 5}}

      assert evaluate(Map.merge(all_fresh(), legacy)).syncs["AmmoSync"].state == :ok
    end
  end

  describe "label families" do
    test "mode-suffixed labels roll up into one family, worst-age wins" do
      # Built without `all_fresh/0` on purpose: that fixture reports a bare
      # "TasksSync" too, which would make the label assertion below ambiguous.
      status = Map.new([run("TasksSync:regular", 10), run("TasksSync:pve", 900)])

      family = evaluate(status).syncs["TasksSync"]

      assert family.age_seconds == 900, "the family is only as fresh as its oldest label"
      assert family.labels == ["TasksSync:pve", "TasksSync:regular"]
    end

    test "a label that merely shares a prefix is NOT absorbed into the family" do
      # `String.starts_with?/2` alone would let a future "ItemsSyncV2" inherit
      # ItemsSync's budget and disappear from view. It must show up as unmonitored
      # (i.e. leave ItemsSync with no runs at all) rather than be silently counted.
      result = evaluate(Map.new([run("ItemsSyncV2", 5)]), 30)

      assert result.syncs["ItemsSync"].labels == []
      assert result.syncs["ItemsSync"].state == :booting
    end

    test "an unexpected label cannot make the verdict green on its own" do
      %{budget_seconds: budget} = evaluate(%{}, 30).syncs["ItemsSync"]

      assert evaluate(Map.new([run("SomethingElse", 5)]), budget + 1).status == :degraded
    end
  end

  describe "the budgets cannot drift out of step with the cadences they cover" do
    test "every budget with a declared owner is at least 2x that owner's interval" do
      # This is the whole reason `Items.Sync.price_interval_ms/0` and friends are
      # public. Without it, changing a tick interval silently leaves the budget
      # behind, and the probe then either false-alarms every cycle or stops being
      # able to detect a stopped feed — both invisible.
      for {prefix, budget_seconds, owner} <- Freshness.budgets(),
          owner != nil,
          is_integer(budget_seconds) do
        {mod, fun} = owner
        interval_seconds = div(apply(mod, fun, []), 1000)

        assert budget_seconds >= 2 * interval_seconds,
               "#{prefix}: budget #{budget_seconds}s must be at least 2x " <>
                 "#{inspect(mod)}.#{fun}/0 (#{interval_seconds}s)"
      end
    end

    test "a family with no cadence owner must be marked :boot_only, never given an age budget" do
      # THE GAP THIS TEST USED TO HAVE, and it was not academic. The version above
      # skips every entry whose owner is `nil` — which was exactly the five feeds that
      # have no timer at all. They had been given the 52h "daily" budget on a false
      # premise, so ~52h after EVERY deploy all five aged out at once and
      # `/health/sync` answered 503 permanently until a restart. The test could not
      # see it because it only inspected the entries that declared an owner.
      #
      # The invariant that actually matters: a numeric budget is a claim that
      # something re-runs the feed. If nothing does, the budget must say so.
      for {prefix, budget_seconds, owner} <- Freshness.budgets() do
        if owner == nil do
          assert budget_seconds == :boot_only,
                 "#{prefix}: has no cadence owner, so an age budget " <>
                   "(#{inspect(budget_seconds)}) is a claim nothing backs — it would " <>
                   "make /health/sync go permanently red on a timer. Mark it " <>
                   ":boot_only, or give it a real schedule and an owner."
        else
          assert is_integer(budget_seconds),
                 "#{prefix}: declares a cadence owner, so it must have a numeric budget"
        end
      end
    end

    # NO FEED IS `:boot_only` ANY MORE. Maps/Ammo/Armor/Hideout/Tasks each carry
    # their own recurring timer now, so all five have real budgets and cadence
    # owners like everything else.
    #
    # The branch stays, and so do these tests, because it is the correct handling
    # for any future feed with no recurring schedule — and because it encodes an
    # incident: an earlier revision gave those timer-less feeds the 52h budget, so
    # `/health/sync` answered 503 permanently about 52 hours after every deploy.
    # Deleting the branch would delete that lesson and leave the next timer-less
    # feed to rediscover it.
    #
    # With no live entry to exercise it, these drive `evaluate/1` with an injected
    # budget table instead. That is what `:budgets` exists for.
    @boot_only_budgets [{"SyntheticBootOnly", :boot_only, nil}]

    test "a boot-only feed never ages out, however long the node has been up" do
      hundred_days = 100 * 24 * 60 * 60
      status = Map.new([run("SyntheticBootOnly", hundred_days)])

      result =
        Freshness.evaluate(
          status: status,
          now: @now,
          uptime_seconds: hundred_days,
          budgets: @boot_only_budgets
        )

      assert result.syncs["SyntheticBootOnly"].state == :ok
      assert result.syncs["SyntheticBootOnly"].age_seconds == hundred_days

      assert result.status == :ok,
             "a boot-only feed ageing must never drive the overall verdict red — " <>
               "that is a 503 on a timer, which is what this exemption exists to stop"
    end

    test "but a boot-only feed that never ran at all is still caught" do
      # The one thing age cannot excuse. A boot-only feed is reached within a
      # minute of boot, so an absent record past the boot grace means the cold
      # start failed and nothing will retry it.
      early =
        Freshness.evaluate(
          status: %{},
          now: @now,
          uptime_seconds: 30,
          budgets: @boot_only_budgets
        )

      assert early.syncs["SyntheticBootOnly"].state == :booting

      late =
        Freshness.evaluate(
          status: %{},
          now: @now,
          uptime_seconds: 6 * 60 * 60,
          budgets: @boot_only_budgets
        )

      assert late.syncs["SyntheticBootOnly"].state == :never_run
      assert late.status == :degraded
    end

    test "a scheduled feed that never reported is booting until its budget, then never_run" do
      # The five wipe-scale feeds take this path now. Bootstrap runs them within a
      # minute of boot, but if Bootstrap failed each one's own fallback timer runs
      # it ~15-75 minutes in — so an absent record is a condition that SELF-HEALS,
      # and judging it against the feed's budget rather than the boot grace is
      # correct. It is no longer "a human must act", it is "give the fallback time".
      assert evaluate(%{}, 6 * 60 * 60).syncs["MapsSync"].state == :booting

      late = evaluate(%{}, 60 * 60 * 60)

      assert late.syncs["MapsSync"].state == :never_run
      assert late.status == :degraded
    end

    test "a wipe-scale feed that FAILED is degraded regardless of how recent it was" do
      status = Map.new([run("HideoutSync", 10, :error)])

      assert Freshness.evaluate(status: status, now: @now, uptime_seconds: 100).syncs[
               "HideoutSync"
             ].state == :failed
    end

    test "every sync label in the codebase belongs to a monitored family" do
      # A new sync that nobody added a budget for is a feed whose failure the probe
      # cannot see. Read the labels out of the source rather than maintaining a
      # second list here that would itself drift.
      declared = for {prefix, _b, _o} <- Freshness.budgets(), do: prefix

      labels =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn path ->
          Regex.scan(~r/with_run\(\s*"([A-Za-z]+)/, File.read!(path), capture: :all_but_first)
        end)
        |> List.flatten()
        |> Enum.uniq()

      assert labels != [], "sanity: expected to find Reporter.with_run/2 call sites"

      for label <- labels do
        assert label in declared,
               "sync label #{inspect(label)} has no budget in EftBuddy.Sync.Freshness, " <>
                 "so a failure of that feed would be invisible to /health/sync"
      end
    end
  end

  describe "uptime_seconds/0" do
    test "is a non-negative number of seconds" do
      assert Freshness.uptime_seconds() >= 0
    end
  end
end
