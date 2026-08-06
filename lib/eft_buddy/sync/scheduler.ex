defmodule EftBuddy.Sync.Scheduler do
  @moduledoc """
  The timer, lock and crash-containment shell every syncer wears.

  ## Why this exists

  Nine modules held a near-identical ~130 lines: the same `@default_interval` /
  `@stagger` / `@bootstrap_offset` / `@fallback_delay` block, the same
  `{:global, __MODULE__}` singleton `start_link/1`, the same `init/1`,
  `handle_info(:sync, …)`, `handle_cast(:bootstrap_complete, …)`,
  `arm_first_run/2`, `safe_run/0`, `jitter/1` and lock wrapper. Copy-paste, not
  abstraction — and it had already drifted into two dialects of the lock alone
  (`acquire_lock/0` + `release_lock/0` in three modules, an inline
  `case :global.set_lock` in five, `with_global_lock/1` in one).

  Duplication that large stops being a style question when the numbers inside it
  become the thing you want to change. A re-cadence across fourteen feeds should
  be fourteen edited lines, not fourteen edited files with fourteen chances to
  leave a comment describing the old value.

  ## What a module still owns

  `do_run/0`. That is the point — everything above is schedule mechanics and
  everything below is what the feed actually does.

  ## Options

    * `:label` — the `EftBuddy.Sync.Reporter` label. Also drives `prefix/0` and
      the entry `EftBuddy.Sync.Freshness` matches on.
    * `:interval` — the compile-time default cadence. See `interval_ms/0` versus
      `effective_interval_ms/0` below, which are deliberately different things.
    * `:stagger` — this feed's slot within its cycle, measured from
      `:bootstrap_complete`. Defaults to 0.
    * `:bootstrap` — how this feed relates to the cold start; see below.
    * `:fallback` — delay to the first run when the bootstrap signal never
      arrives. Defaults to 15 minutes, and the effective value is
      `fallback + stagger`.
    * `:lock` — `:own` for `{__MODULE__, :running}`, or an explicit term shared
      with the other feeds that write the same tables.
    * `:config_key` — enables a runtime interval override under
      `config :eft_buddy, :sync_intervals, [key: ms]`.

  ## `:bootstrap` unifies two meanings that used to live only in prose

  `@bootstrap_offset` was `@default_interval + @stagger` in five modules and `0`
  or `1 min` in two others, with a paragraph in each explaining which and why.
  The distinction is real and worth naming:

    * `:ran` — Bootstrap runs this feed itself, synchronously, during the cold
      start. By the time `:bootstrap_complete` arrives the work has already
      happened, so the first scheduled run is a FULL INTERVAL away. Arming at
      zero would immediately re-sync the whole snapshot for nothing.
    * `:released` — Bootstrap only *releases* this feed; it has never run. The
      first run is its stagger away, which for the first slot means "now".
    * `:chained` — armed by another module's cast rather than by Bootstrap
      (`EftBuddy.Wiki.Sync` off `EftBuddy.Events.Sync`'s `:events_complete`). It
      still keeps its own recurring timer.
    * `:none` — no cast wiring at all.

  ## Two hooks, so no module has to override a GenServer callback

    * `next_interval/2` — given the run's result and the configured interval,
      how long until the next tick. `EftBuddy.Wiki.Sync` shortens it after
      `{:error, :no_tasks}`; the default handles `{:error, :already_running}` by
      retrying in minutes rather than a full cycle, which is what makes a lock
      shared across a family of feeds cheap.
    * `after_run/1` — post-run fan-out. `EftBuddy.Events.Sync` casts
      `:events_complete` to the wiki scrape from here.

  Overriding `handle_info/2` directly instead would put two clause groups for the
  same callback in one module, which the compiler warns about and which reads as
  an accident.

  ## Jitter is capped

  `:rand.uniform(div(interval, 10) + 1)` reads as "±10%", which is fine at the
  minutes-to-hours scale it was written for and useless at twelve hours: 0–72
  minutes of one-sided drift, against staggers spaced 25 minutes apart. The
  stagger table would have been decorative.

  These are `{:global, __MODULE__}` singletons, so only one node runs each feed
  and jitter is not smoothing a thundering herd — it only has to stop several
  restarts landing on the same instant. Five minutes is more than enough for
  that and leaves the schedule meaning what it says.
  """

  @doc """
  The feed's actual work, wrapped by `run/0` in the cluster-wide lock.

  Must return `{:ok, summary}`, `{:skip, reason}` or `{:error, reason}` — the
  shapes `EftBuddy.Sync.Reporter.outcome/1` distinguishes.
  """
  @callback do_run() :: {:ok, any()} | {:skip, any()} | {:error, any()}

  @doc """
  Milliseconds until the next tick, given the run's result.

  Defaults to the configured interval, with a short retry on
  `{:error, :already_running}`.
  """
  @callback next_interval(result :: any(), interval :: non_neg_integer()) ::
              non_neg_integer()

  @doc "Post-run fan-out. Defaults to a no-op."
  @callback after_run(result :: any()) :: any()

  @doc """
  Casts other than `:bootstrap_complete` and `:sync_now`.

  An override must supply a catch-all clause of its own; `defoverridable`
  replaces the default rather than falling through to it.
  """
  @callback handle_extra_cast(msg :: any(), state :: map()) :: {:noreply, map()}

  @optional_callbacks next_interval: 2, after_run: 1, handle_extra_cast: 2

  @default_fallback_ms 15 * 60 * 1_000

  # Enough to decorrelate restarts, small enough to leave a stagger table
  # meaningful. See the moduledoc.
  @max_jitter_ms 5 * 60 * 1_000

  # How soon to retry after losing the lock to another feed in the same family.
  # Minutes, not a full cycle: contention is expected and self-healing, and a
  # loser that waited twelve hours would turn a five-minute overlap into half a
  # day of stale data.
  @contention_retry_ms 5 * 60 * 1_000

  @doc "Milliseconds of jitter for a delay of `ms`. Capped — see the moduledoc."
  def jitter(ms) when is_integer(ms) and ms > 0,
    do: :rand.uniform(min(div(ms, 10), @max_jitter_ms) + 1)

  def jitter(_ms), do: 0

  @doc """
  Delay to the first run when `:bootstrap_complete` never arrives.

  Short rather than a full cycle: the signal is missing because Bootstrap died,
  which means this feed has NOT run and its table may be empty. The effective
  value is this plus the feed's stagger, so the fallback ordering matches the
  normal ordering.
  """
  def default_fallback_ms, do: @default_fallback_ms

  @doc false
  def contention_retry_ms, do: @contention_retry_ms

  @doc false
  def max_jitter_ms, do: @max_jitter_ms

  @doc """
  Coerce a configured interval to a usable non-negative integer.

  `Process.send_after/3` only accepts non-negative integers, and a value that
  arrived from config could be a float or a string. Falls back to `default`
  rather than raising: a bad interval should make a feed run on its default
  cadence, not fail to start.
  """
  def normalize_ms(value, _default, _key) when is_integer(value) and value >= 0, do: value

  def normalize_ms(value, _default, _key) when is_float(value) and value >= 0.0,
    do: trunc(value)

  def normalize_ms(nil, default, _key), do: default

  def normalize_ms(value, default, key) do
    require Logger

    Logger.warning(
      "[Sync.Scheduler] :sync_intervals[#{inspect(key)}] is #{inspect(value)}, " <>
        "which is not a usable interval; falling back to #{default}ms."
    )

    default
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      use GenServer

      @behaviour EftBuddy.Sync.Scheduler

      require Logger

      alias EftBuddy.Sync.Reporter
      alias EftBuddy.Sync.Scheduler

      @scheduler_label Keyword.fetch!(opts, :label)
      @scheduler_interval Keyword.fetch!(opts, :interval)
      @scheduler_stagger Keyword.get(opts, :stagger, 0)
      @scheduler_bootstrap Keyword.get(opts, :bootstrap, :ran)
      @scheduler_config_key Keyword.get(opts, :config_key)

      @scheduler_fallback Keyword.get(opts, :fallback, Scheduler.default_fallback_ms()) +
                            @scheduler_stagger

      # The lock's RESOURCE id. The requester id is supplied per call in
      # `with_lock/1` and must be `self()` — see the comment there.
      @lock_resource (case Keyword.get(opts, :lock, :own) do
                        :own -> {__MODULE__, :running}
                        explicit -> explicit
                      end)

      # `:ran` means Bootstrap already did this work synchronously, so the first
      # scheduled run is a full interval out. `:released` means it has not run.
      @scheduler_bootstrap_offset (case @scheduler_bootstrap do
                                     :ran -> @scheduler_interval + @scheduler_stagger
                                     _ -> @scheduler_stagger
                                   end)

      @doc false
      # The COMPILE-TIME default, and deliberately not the effective value.
      #
      # `EftBuddy.Sync.Freshness` calibrates its staleness budget against this and
      # `freshness_test.exs` asserts `budget >= 2 * interval_ms()`. If this
      # returned a runtime override, an operator could set an interval that breaks
      # the health probe's invariant in production while the test — reading
      # default config — stayed green. Worse than having no override at all.
      def interval_ms, do: @scheduler_interval

      @doc false
      # What this process actually ticks on. Reads
      #   config :eft_buddy, :sync_intervals, [ammo: 86_400_000]
      def effective_interval_ms do
        case @scheduler_config_key do
          nil ->
            @scheduler_interval

          key ->
            :eft_buddy
            |> Application.get_env(:sync_intervals, [])
            |> Keyword.get(key)
            |> Scheduler.normalize_ms(@scheduler_interval, key)
        end
      end

      @doc false
      def stagger_ms, do: @scheduler_stagger

      @doc false
      def bootstrap_mode, do: @scheduler_bootstrap

      @doc false
      def label, do: @scheduler_label

      @doc false
      # The resource this feed serialises on. Feeds that write the same tables
      # share it by passing `lock:` explicitly.
      def lock_id, do: @lock_resource

      @doc false
      # Cluster-wide singleton: only one node registers the GenServer, the rest
      # `:ignore` their start_link and leave the supervisor slot empty.
      def start_link(opts \\ []) do
        case GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, _pid}} ->
            Logger.info("[#{prefix()}] Another node already runs #{@scheduler_label}; idle here.")

            :ignore
        end
      end

      @doc "Trigger a run asynchronously (e.g. from IEx)."
      def sync_now, do: GenServer.cast({:global, __MODULE__}, :sync_now)

      @doc """
      Run synchronously under the cluster-wide lock.

      Returns whatever `do_run/0` returns, or `{:error, :already_running}` when
      another run in this lock's family holds it.
      """
      def run, do: with_lock(&do_run/0)

      @doc false
      # Public so a module with more than one entry point can wrap the second in
      # the same lock.
      def with_lock(fun) when is_function(fun, 0) do
        nodes = [node() | Node.list()]

        # `:global.set_lock/3` takes `{ResourceId, LockRequesterId}`, and the
        # REQUESTER MUST BE `self()`. Every syncer previously passed
        # `{__MODULE__, :running}`, which reads as resource `__MODULE__` and
        # requester `:running` — a constant. `:global` grants a lock re-entrantly
        # to the same requester by design, so two processes both naming
        # `:running` both succeeded and the lock excluded nothing. Not on one
        # node, not across the cluster, ever.
        #
        # With `self()` the exclusion is real, while feeds that deliberately
        # share a resource still serialise against each other because only the
        # requester differs. Re-entrancy within one process is preserved, which is
        # what a nested `run/0` inside a run relies on.
        id = {@lock_resource, self()}

        case :global.set_lock(id, nodes, 0) do
          true ->
            try do
              fun.()
            after
              :global.del_lock(id, nodes)
            end

          false ->
            # `:info`, not `:warning`. Where a lock is shared across a family of
            # feeds, contention is an expected and self-healing condition — the
            # loser re-arms in minutes via `next_interval/2` — and a warning on
            # every cycle trains its reader to ignore the whole stream.
            Logger.info(
              "[#{prefix()}] Skipped: #{inspect(@lock_resource)} is held by another run."
            )

            {:error, :already_running}
        end
      end

      # ── Hooks ────────────────────────────────────────────

      @doc false
      # A loser retries in minutes rather than a full cycle. This is what makes a
      # lock shared across the items family cheap: ordering between feeds becomes
      # a retry rather than a constraint.
      def next_interval({:error, :already_running}, _interval),
        do: Scheduler.contention_retry_ms()

      def next_interval(_result, interval), do: interval

      @doc false
      def after_run(_result), do: :ok

      @doc false
      # Casts beyond `:bootstrap_complete` and `:sync_now`. Override with a full
      # set of clauses INCLUDING a catch-all — `defoverridable` replaces this
      # definition rather than adding to it.
      def handle_extra_cast(_msg, state), do: {:noreply, state}

      defoverridable next_interval: 2, after_run: 1, handle_extra_cast: 2, run: 0

      # ── Server ───────────────────────────────────────────

      @impl true
      def init(opts) do
        interval = Keyword.get(opts, :interval, effective_interval_ms())
        first = Keyword.get(opts, :first_run_delay, @scheduler_fallback)

        warn_if_interval_outruns_budget(interval)

        timer = Process.send_after(self(), :sync, first + Scheduler.jitter(first))
        {:ok, %{interval: interval, timer: timer}}
      end

      @impl true
      def handle_info(:sync, %{interval: interval} = state) do
        result = safe_run()
        after_run(result)

        next = next_interval(result, interval)
        timer = Process.send_after(self(), :sync, next + Scheduler.jitter(next))

        {:noreply, %{state | timer: timer}}
      end

      def handle_info(_msg, state), do: {:noreply, state}

      @impl true
      def handle_cast(:bootstrap_complete, state) do
        {:noreply, arm_first_run(state, @scheduler_bootstrap_offset)}
      end

      def handle_cast(:sync_now, state) do
        safe_run()
        {:noreply, state}
      end

      # Anything else goes to the hook, so a module with its own cast — the wiki
      # scrape's `:events_complete` hand-off — does not have to add a
      # `handle_cast/2` clause of its own further down the file, which would
      # split the callback's clause group and warn.
      def handle_cast(msg, state), do: handle_extra_cast(msg, state)

      @doc false
      # Cancel the standing timer and re-arm `offset` from now. Used by the
      # bootstrap cast and by any chained hand-off.
      def arm_first_run(state, offset) do
        if state.timer, do: Process.cancel_timer(state.timer)
        timer = Process.send_after(self(), :sync, offset + Scheduler.jitter(offset))
        %{state | timer: timer}
      end

      @doc false
      # Never lets a run take the GenServer down. A feed that crashes should miss
      # a tick, not lose its timer.
      def safe_run do
        case run() do
          {:ok, summary} ->
            Logger.info("[#{prefix()}] done: #{inspect(summary)}")
            {:ok, summary}

          {:error, :already_running} ->
            {:error, :already_running}

          {:skip, reason} ->
            Logger.info("[#{prefix()}] skipped: #{inspect(reason)}")
            {:skip, reason}

          {:error, reason} ->
            Logger.warning("[#{prefix()}] run ended early: #{inspect(reason)}")
            {:error, reason}

          other ->
            other
        end
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] crash: #{Exception.message(e)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          {:error, {:crash, Exception.message(e)}}
      end

      @doc false
      def prefix, do: Reporter.colorize_label(@scheduler_label)

      # An override that outruns the health probe's budget is legal but almost
      # certainly a mistake: `/health/sync` would then report this family stale on
      # a schedule rather than on a fault. Warned rather than capped — an operator
      # reaching for the escape hatch should get the value they asked for — but
      # loudly enough that the consequence is not a surprise at 3am.
      defp warn_if_interval_outruns_budget(interval) do
        case EftBuddy.Sync.Freshness.budget_seconds(@scheduler_label) do
          budget when is_integer(budget) and interval > budget * 1_000 / 2 ->
            Logger.warning(
              "[#{prefix()}] interval #{interval}ms exceeds half the #{budget}s staleness " <>
                "budget for #{@scheduler_label}; /health/sync will report this family " <>
                "stale on a schedule rather than on a fault."
            )

          _ ->
            :ok
        end
      end
    end
  end
end
