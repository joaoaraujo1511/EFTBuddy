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

  ## Age means "since it last worked", not "since it last ran"

  The distinction only matters in the case that matters. A feed can tick exactly on
  schedule and write nothing every time — `EftBuddy.Items.Sync`'s barter step
  returns `{:skip, "no resolvable barters…"}` when the traders it needs are not in
  the database yet — and if age were measured from the last *run*, every one of
  those ticks would refresh it. The feed would report current forever while serving
  data that never arrived.

  So this ages on `last_ok_at`. A feed that only skips, or only errors, goes stale
  on its own budget like any stopped feed, and no new state or threshold is needed
  to express it. That also covers the case a single sequential pipeline used to
  hide: once feeds have independent timers, one of them starting before its
  dependency has populated is an ordinary occurrence, and the difference between
  "skipped once on a cold start" and "has skipped every run for a day" has to be
  visible.

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

  # The three cadences the feeds run on, each just over 2x its interval so a
  # single slipped tick is never an incident. `freshness_test.exs` enforces the
  # 2x rule against each feed's real `interval_ms/0`.
  @six_hourly 14 * 60 * 60
  @twelve_hourly 26 * 60 * 60

  @budgets [
    # Ticks every 10 minutes; 2h is 12 missed ticks. Tighter than everything else
    # because prices are the only genuinely volatile data in the app.
    {"PricesSync", 2 * 60 * 60, {EftBuddy.Items.Sync, :price_interval_ms}},

    # Quest-shaped feeds, 6h. Quests are the only content that changes between
    # wipes — tarkov.dev re-tags them during events and new ones arrive with
    # patches — so they refresh twice as often as the structural data.
    {"TasksSync", @six_hourly, {EftBuddy.Tasks.Sync, :interval_ms}},
    {"WikiSync", @six_hourly, {EftBuddy.Wiki.Sync, :interval_ms}},

    # Structural tarkov.dev feeds, 12h.
    #
    # `EconomySync` is the per-mode vendor-economy pass — `item_prices.base_price`,
    # `sell_for`, `buy_for`. It used to label itself `PricesSync:<mode>`, which
    # `matches?/2` folded into the PricesSync family above, so a pass running on
    # the structural cadence was judged against the ten-minute feed's 2h budget.
    # `evaluate_family/5` ages a family on its OLDEST label, so that family read
    # `:stale` for roughly four of every six hours and `/health/sync` answered 503
    # for most of every cycle — before this change, and for 10 of every 12 after
    # it. A distinct label is the whole fix.
    {"ItemsSync", @twelve_hourly, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"EconomySync", @twelve_hourly, {EftBuddy.Items.Sync, :full_interval_ms}},

    # These four still run inside `Items.Sync`'s full pipeline and inherit its
    # cadence, which is why they share its owner. They get their own labels,
    # budgets and timers when they are split into modules of their own; until
    # then a shared owner is the honest description.
    {"BartersSync", @twelve_hourly, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"CraftsSync", @twelve_hourly, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"FleaSettingsSync", @twelve_hourly, {EftBuddy.Items.Sync, :full_interval_ms}},
    {"QuestItemsSync", @twelve_hourly, {EftBuddy.Items.Sync, :full_interval_ms}},

    # The wipe-scale feeds. These WERE `@boot_only` — they had no timer at all,
    # so they could not be judged on age and were exempted. They now each own a
    # recurring GenServer timer (`EftBuddy.Sync.Bootstrap` runs them once at
    # boot, their own schedule thereafter), so the exemption no longer applies
    # and they get real budgets like everything else.
    {"MapsSync", @twelve_hourly, {EftBuddy.Maps.Sync, :interval_ms}},
    {"AmmoSync", @twelve_hourly, {EftBuddy.Ammo.Sync, :interval_ms}},
    {"ArmorSync", @twelve_hourly, {EftBuddy.Armor.Sync, :interval_ms}},
    {"HideoutSync", @twelve_hourly, {EftBuddy.Hideout.Sync, :interval_ms}},

    # Fandom scrapes. Events feeds the blacklist the quest scrape honours; the
    # storyline changes only on major patches, so it stays daily.
    {"EventsSync", @twelve_hourly, {EftBuddy.Events.Sync, :interval_ms}},
    {"ChaptersSync", @daily_feed, {EftBuddy.Chapters.Sync, :interval_ms}}
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
  Staleness budget in seconds for one label prefix, or `nil` if unknown or
  `:boot_only`.

  Exists so `EftBuddy.Cache.Warmer` can give a warm-written entry a TTL matched
  to the feed that owns it, instead of the cache's flat default. This table is
  already the single source of truth for "how often does this feed run, and how
  long before absence is a problem", and it is drift-tested against the real
  cadences — so deriving the TTL from it means a feed whose interval changes
  cannot leave a cache TTL behind at the old number.
  """
  @spec budget_seconds(String.t()) :: pos_integer() | nil
  def budget_seconds(prefix) when is_binary(prefix) do
    Enum.find_value(@budgets, fn
      {^prefix, budget, _owner} when is_integer(budget) -> budget
      _ -> nil
    end)
  end

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
        # Aged from the last SUCCESSFUL run, not the last run. A feed that ticks
        # on schedule and declines every time — `{:skip, "no resolvable barters"}`
        # because its dependency has not populated yet — refreshes `at` on every
        # tick and would look permanently current while writing nothing. Ageing on
        # success instead means the family goes stale on its own budget, and it
        # covers errors and any future non-`:ok` terminal state without a new
        # threshold to tune.
        #
        # The `s.outcome == :ok` arm is a fallback for records written before
        # `last_ok_at` existed, in the same spirit as the `Map.get/3` on
        # `:refusals` below. It is load-bearing across a deploy: the status table
        # survives in ETS while the code changes underneath it.
        succeeded_at = fn s -> Map.get(s, :last_ok_at) || if(s.outcome == :ok, do: s.at) end

        ages =
          for {_label, s} <- runs,
              at = succeeded_at.(s),
              not is_nil(at),
              do: DateTime.diff(now, at)

        # No label in this family has ever succeeded — it has only skipped, or
        # only errored. Judged against uptime for the same reason the
        # never-reported branch above is: otherwise every deploy would report
        # every feed degraded for its first cycle.
        never_succeeded? = ages == []
        oldest = if never_succeeded?, do: nil, else: Enum.max(ages)
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
            never_succeeded? and uptime > budget -> :stale
            never_succeeded? -> :booting
            oldest > budget -> :stale
            true -> :ok
          end

        %{
          state: state,
          budget_seconds: budget,
          # Seconds since the last SUCCESSFUL run. `nil` when there has not been
          # one, which is the same thing the never-reported branch reports and for
          # the same reason: "no successful run to measure from" and "zero seconds
          # since one" are opposite diagnoses and must not render identically.
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
