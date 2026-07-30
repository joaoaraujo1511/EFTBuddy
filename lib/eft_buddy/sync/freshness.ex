defmodule EftBuddy.Sync.Freshness do
  @moduledoc """
  Decides whether the background data feeds are **fresh enough to serve**, and turns
  that into a readiness verdict.

  ## Why this exists

  `GET /health` used to answer `200 {"status":"ok"}` whenever `SELECT 1` succeeded.
  Every other thing that can go wrong with this app is invisible to that: the site
  has no user-authored content, so if a sync stops or truncates, the pages keep
  rendering perfectly and simply show **stale or missing game data as fact**. The
  audit's blunt version — "the app's most dangerous property is that it silently
  presents wrong data, and it is the one thing none of its instrumentation can
  detect".

  A sync that has stopped emits no events at all, so its absence cannot be noticed
  by anything event-driven. Freshness therefore has to be evaluated by *asking how
  old each feed is*, which is what this module does over
  `EftBuddy.Sync.Reporter.status/0`.

  ## Why a fresh boot is not "degraded"

  A probe that reports unhealthy for the first minutes of every deploy trains its
  reader to ignore it, and an orchestrator will refuse to bring the instance into
  rotation at all. So a feed that has not run *yet* is only a problem once the
  process has been up longer than that feed's own budget — before that it is
  `:booting`, which is healthy.

  ## The budgets

  Deliberately generous multiples of each feed's real cadence: the question being
  answered is "has this stopped?", not "is this a few minutes late?". A tick that
  merely slipped past a retry is not an incident, and false alarms cost more than
  the delay in noticing.

  `Reporter` labels carry a mode suffix (`TasksSync:regular`, `PricesSync:pve`), so
  budgets are matched by **prefix** and a family's verdict is the worst among its
  labels.
  """

  alias EftBuddy.Sync.Reporter

  # {label_prefix, budget_seconds, cadence_owner}
  #
  # `cadence_owner` is `{module, function}` returning that feed's real tick interval
  # in milliseconds, or `nil` where the cadence is not expressed as a timer. It is
  # not used at runtime — it exists so `freshness_test.exs` can assert every budget
  # is comfortably larger than the interval it is supposed to cover, which turns the
  # usual "keep these two numbers in step" comment into a test failure.
  # The rule these follow is **at least twice the cadence, plus slack**: tolerate
  # exactly one missed run, because one miss is a blip (an upstream hiccup, a
  # network blip, a retry that slipped) and two is a pattern. The drift test in
  # `freshness_test.exs` enforces the 2x half wherever an owner is declared — it is
  # what caught a 36h budget sitting at only 1.5x a 24h cadence, which would have
  # reported "stale" on every single missed daily scrape.
  @daily_feed 52 * 60 * 60

  # `:boot_only` — a feed with NO recurring timer, run exactly once by
  # `EftBuddy.Sync.Bootstrap` and then never again for the life of the node.
  #
  # These CANNOT be judged on age, and getting that wrong is not a subtle bug: an
  # earlier revision of this table gave them the 52h `@daily_feed` budget on the
  # premise that they were "daily, whether from the recurring boot cycle or their own
  # timers". There is no recurring boot cycle. So ~52 hours after every single deploy
  # all five crossed the budget at once, the verdict went `:degraded`, and
  # `/health/sync` answered 503 permanently until the process restarted — which is
  # precisely the outcome this module's moduledoc names as the thing to avoid, and
  # which would have pulled the instance out of rotation on day three of a launch.
  #
  # Reported but never stale-degraded, with one exception: they must still have run
  # at all. `Bootstrap` reaches them within a minute of boot, so past
  # `@boot_grace` an absent record means the cold start genuinely failed.
  #
  # WHEN THESE GAIN A REAL CADENCE, give them a numeric budget and a cadence owner.
  @boot_only :boot_only
  @boot_grace 60 * 60

  @budgets [
    # Ticks every ~15 minutes; 2h is 8 missed ticks. Tighter than everything else
    # because prices are the only genuinely volatile data in the app.
    {"PricesSync", 2 * 60 * 60, {EftBuddy.Items.Sync, :price_interval_ms}},

    # Items keeps its own recurring tick, and the three sub-steps that run inside the
    # same pipeline inherit its cadence.
    {"ItemsSync", @daily_feed, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"BartersSync", @daily_feed, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"CraftsSync", @daily_feed, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"FleaSettingsSync", @daily_feed, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"QuestItemsSync", @daily_feed, {EftBuddy.Items.Sync, :full_interval_ms}},

    # The wipe-scale feeds. These WERE `@boot_only` — they had no timer at all,
    # so they could not be judged on age and were exempted. They now each own a
    # recurring GenServer timer (`EftBuddy.Sync.Bootstrap` runs them once at
    # boot, their own schedule thereafter), so the exemption no longer applies
    # and they get real budgets like everything else.
    #
    # Tasks ticks twice as often as the rest because quests are the only one of
    # the five that changes between wipes — see `EftBuddy.Tasks.Sync`. 26h is
    # just over 2x its 12h cadence; the other four take `@daily_feed`, which is
    # just over 2x their 24h. `freshness_test.exs` enforces the 2x rule.
    {"MapsSync", @daily_feed, {EftBuddy.Maps.Sync, :interval_ms}},
    {"AmmoSync", @daily_feed, {EftBuddy.Ammo.Sync, :interval_ms}},
    {"ArmorSync", @daily_feed, {EftBuddy.Armor.Sync, :interval_ms}},
    {"HideoutSync", @daily_feed, {EftBuddy.Hideout.Sync, :interval_ms}},
    {"TasksSync", 26 * 60 * 60, {EftBuddy.Tasks.Sync, :interval_ms}},

    # Wiki scrapers: daily by their own timers.
    {"ChaptersSync", @daily_feed, {EftBuddy.Chapters.Sync, :interval_ms}},
    {"EventsSync", @daily_feed, {EftBuddy.Events.Sync, :interval_ms}},
    {"WikiSync", @daily_feed, {EftBuddy.Wiki.Sync, :interval_ms}}
  ]

  @type state :: :ok | :booting | :stale | :failed | :guard_tripped | :never_run
  @type family :: %{
          state: state(),
          budget_seconds: pos_integer(),
          age_seconds: non_neg_integer() | nil,
          refusals: non_neg_integer(),
          labels: [String.t()]
        }

  @doc "Every monitored feed family and its staleness budget, in seconds."
  @spec budgets() :: [{String.t(), pos_integer(), {module(), atom()} | nil}]
  def budgets, do: @budgets

  @doc """
  Readiness verdict for the background feeds.

  Returns `%{status: :ok | :degraded, uptime_seconds: n, syncs: %{family => t}}`.

  ## Options

    * `:status` - the `Reporter.status/0` map to evaluate (defaults to reading it)
    * `:now` - the reference time (defaults to now)
    * `:uptime_seconds` - how long this node has been up (defaults to VM uptime)
    * `:budgets` - the budget table to evaluate against (defaults to `budgets/0`)

  All four are injectable so the whole decision is a pure function under test —
  a probe whose logic can only be exercised by waiting 36 hours is a probe nobody
  verifies.

  `:budgets` exists specifically to keep the `@boot_only` branch testable. No
  feed carries that marker today (all five that did now have real timers), but
  the branch must stay: it is the correct handling for any future feed with no
  recurring schedule, and it encodes a real incident — an earlier revision gave
  those timer-less feeds a 52h age budget, so `/health/sync` answered 503
  permanently about 52 hours after every deploy. Without injection that branch
  would have no live entry to exercise it and would rot.
  """
  @spec evaluate(keyword()) :: %{
          status: :ok | :degraded,
          uptime_seconds: non_neg_integer(),
          syncs: %{String.t() => family()}
        }
  def evaluate(opts \\ []) do
    status = Keyword.get_lazy(opts, :status, &Reporter.status/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    uptime = Keyword.get_lazy(opts, :uptime_seconds, &uptime_seconds/0)
    budgets = Keyword.get(opts, :budgets, @budgets)

    syncs =
      Map.new(budgets, fn {prefix, budget, _owner} ->
        {prefix, evaluate_family(prefix, budget, status, now, uptime)}
      end)

    overall = if Enum.any?(syncs, fn {_k, f} -> degraded?(f.state) end), do: :degraded, else: :ok

    %{status: overall, uptime_seconds: uptime, syncs: syncs}
  end

  @doc "Whether a family state should fail readiness."
  @spec degraded?(state()) :: boolean()
  def degraded?(state), do: state in [:stale, :failed, :guard_tripped, :never_run]

  # ── Internals ──────────────────────────────────────────────────────

  defp evaluate_family(prefix, budget, status, now, uptime) do
    runs = for {label, s} <- status, matches?(label, prefix), do: {label, s}

    case runs do
      [] ->
        # Never reported. Only a problem once we have been up long enough that it
        # should have run by now — otherwise every deploy reports degraded. For a
        # boot-only feed that deadline is the boot grace, not its (absent) cadence.
        deadline = if budget == @boot_only, do: @boot_grace, else: budget
        state = if uptime > deadline, do: :never_run, else: :booting

        %{state: state, budget_seconds: budget, age_seconds: nil, refusals: 0, labels: []}

      runs ->
        ages = for {_label, s} <- runs, do: DateTime.diff(now, s.at)
        oldest = Enum.max(ages)
        failed? = Enum.any?(runs, fn {_label, s} -> s.outcome == :error end)

        # A run that refused a destructive prune reports `outcome: :ok` — it did
        # complete. But it completed by DECLINING to trust its own snapshot, which
        # means the data being served is knowingly not what upstream last said. That
        # is the app's most dangerous state and `outcome` cannot express it, so it is
        # read separately. `Map.get/3` because records written before this field
        # existed do not carry it.
        refusals = Enum.sum(for {_label, s} <- runs, do: Map.get(s, :refusals, 0))

        state =
          cond do
            failed? -> :failed
            refusals > 0 -> :guard_tripped
            # A boot-only feed is never judged on age: it ran once, at boot, and by
            # design will not run again. Ageing it out would make the probe report
            # degraded on a schedule rather than on a fault.
            budget == @boot_only -> :ok
            oldest > budget -> :stale
            true -> :ok
          end

        %{
          state: state,
          budget_seconds: budget,
          age_seconds: oldest,
          refusals: refusals,
          labels: runs |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        }
    end
  end

  # A label matches its family either exactly (`"ItemsSync"`) or with a mode suffix
  # (`"TasksSync:regular"`). Deliberately NOT a bare `String.starts_with?/2`, which
  # would let a future `"ItemsSyncV2"` be silently absorbed into `"ItemsSync"`'s
  # budget instead of showing up as unmonitored.
  defp matches?(label, prefix) do
    label == prefix or String.starts_with?(label, prefix <> ":")
  end

  @doc """
  Seconds this node has been running.

  Derived from the VM's own start time rather than `:erlang.statistics(:wall_clock)`,
  whose second element is "since the last call" and would therefore make every
  reader of this function interfere with every other.
  """
  @spec uptime_seconds() :: non_neg_integer()
  def uptime_seconds do
    System.convert_time_unit(
      :erlang.monotonic_time() - :erlang.system_info(:start_time),
      :native,
      :second
    )
  end
end
