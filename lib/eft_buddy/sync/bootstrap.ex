defmodule EftBuddy.Sync.Bootstrap do
  @moduledoc """
  One-shot, supervised orchestrator that runs the cold-start sync sequence on
  application boot.

  **The sequence itself lives in `EftBuddy.Sync.Registry.cold_start_steps/0`**,
  not here. This moduledoc used to enumerate it, and the enumeration went stale:
  it described five steps in an order that had not been current since Ammo and
  Armor were added, and a reader trusting it would have had the FK reasoning
  right and the steps wrong. What is worth writing by hand is *why* the order is
  what it is — that does not change when a feed is inserted.

  ## Why the order is the order

  It is the foreign-key graph.

  Items are the root: categories, vendors and prices come with them, and almost
  everything below resolves an id against the `items` table. Maps run before
  Tasks so `tasks.map_id` resolves against the full rich map set rather than the
  bare fallback rows Tasks would otherwise write, which also leaves the `maps`
  table's lifecycle owned by the Maps sync. Hideout and Tasks between them seed
  the complete trader set — Tasks contributes Ref, Fence and Lightkeeper, which
  never appear in hideout data but *are* referenced by barters. Barters and
  crafts come last because their parents need items, station levels, the full
  trader set, and the tasks each one resolves its `task_unlock` against.

  Most steps degrade rather than fail when an earlier one did: they drop the
  item-keyed slice they cannot resolve, write the rest, and re-link next run. The
  exception is marked `requires:` in the registry — a step whose every parent FK
  resolves against a previous step would fetch its whole set from the API only to
  sanitise all of it away, so it is skipped up front instead of hammering an
  already-struggling upstream.

  Bootstrap runs these feeds *first*; it is not what keeps them running. Each is
  a GenServer with its own timer, and any can be re-run on demand from IEx:

      EftBuddy.Maps.Sync.run()

  ## The completion cast

  Bootstrap casts `:bootstrap_complete` to a feed the moment THAT FEED's own
  cold-start step succeeds — the `:notify` field on each step in
  `EftBuddy.Sync.Registry.cold_start_steps/0` names the recipient. The cast is a
  SCHEDULING signal, not a trigger: the work already happened, here in `do_run/0`,
  so each feed arms its first *recurring* run a full interval plus its own stagger
  away. That spaces the feeds across the cycle and preserves the FK ordering
  within each one.

  ## Why per-step, and not once at the end

  It was once at the end, and that was fine while the sequence took seconds.

  Adding the Fandom scrapes made the sequence longer than the SHORTEST fallback in
  the registry, and a fallback exists to mean "Bootstrap died, run yourself". Once
  the sequence outlasts one, "Bootstrap is slow" and "Bootstrap is dead" become
  the same observation from inside a feed.

  `EftBuddy.Chapters.Sync` proved it on the first deploy: a zero stagger puts its
  step early in the Fandom group and its fallback fifteen minutes out, so it
  finished at 21:56, sat idle holding no lock while the events scrape ran for
  thirteen minutes, and at 22:09 re-scraped the eleven pages it had just written.
  Nothing was corrupted — every feed is idempotent and lock-guarded — but it
  doubled the load on a rate-limited third party inside the window that party is
  already being hammered.

  Releasing each feed when its own work finishes also fixes a wart that predates
  the scrapes: the blanket cast released every feed regardless of whether its step
  had SUCCEEDED, so a feed whose cold start failed still armed a full interval out
  and served an empty table until its next cycle. Only `{:ok, _}` releases a feed
  now; anything else leaves it on the short fallback, which is what that fallback
  is for. `report_unnotified/1` logs who those are.

  ## The modes the scheduler still understands

  `:released` (Bootstrap merely lets a feed start, so it arms at its stagger) and
  `:chained` (armed by another feed's cast instead). The three Fandom scrapes used
  to be those, and it went wrong in a way worth remembering: for a `:released`
  feed the stagger doubles as the delay to its first run ever, and the stagger is
  really a slot within the recurring cycle. When the feeds were re-cadenced, the
  events scrape's slot moved from 1 minute to 180 and its first run moved with it
  — so a fresh database had no events for three hours, no quest pages for two, and
  any restart inside that window started the wait over. Nothing errored and
  `/health/sync` read healthy throughout, because a feed that has not run yet is
  `:booting`, not stale.

  Running every feed here means a stagger only ever means what it says.

  Every feed also keeps a shorter fallback timer for the case where the cast never
  arrives — which now means either that Bootstrap failed outright, or that this
  feed's own step did not succeed.

  ## Why this exists

  Before this module, each syncer scheduled its own first tick on
  a hard-coded delay (Items at +5 s, Hideout at +30 s) and Items
  also tried to populate barters/crafts inside that first tick.
  But barters/crafts need traders + `hideout_station_levels`, both
  of which are written by `Hideout.Sync` — which fired *after*
  Items. On a fresh DB the first Items tick filtered every
  barter/craft out (`sanitize_barters/3` / `sanitize_crafts/3`
  drops anything whose trader / station-level FK can't be
  resolved), so the BARTER ITEMS / CRAFTED ITEMS scopes on the
  Items tab silently rendered empty until the next 5-minute
  Items tick. Bootstrap eliminates that race by running the four
  phases in the only order that actually satisfies the FK graph.

  ## Failure handling

  Each step is wrapped in its own try/rescue. A failure in one
  step is logged and the sequence continues — a partial sync
  (e.g. items present but tasks missing because the API choked
  mid-run) is still more useful than no sync at all, and the
  individual steady-state schedulers will retry on their own
  cadence afterwards.

  The one dependency-aware exception: step 5 (barters & crafts)
  resolves *every* parent FK against the items from step 1, so if
  step 1 failed it is skipped outright rather than run — otherwise
  it would fetch the whole barter/craft set from the API only to
  sanitise all of it away (`sanitize_barters/3` / `sanitize_crafts/3`
  drop anything whose FK can't be resolved). Steps 2–4 still run
  on a failed step 1: they only drop the item-keyed slices they
  can't resolve and otherwise write useful rows.

  ## Cluster safety

  Multi-node deploys: only one node should run the cold start.
  The Task acquires a cluster-wide lock with `:global.set_lock/3`
  on entry; nodes that don't get the lock log and exit normally.
  Each downstream sync also takes its own per-module lock, so
  even without this lock we'd be safe — this is a layer of
  belt-and-braces plus a single "[Bootstrap] starting" log line
  on the elected node.

  ## Restart strategy

  `use Task, restart: :temporary` — a Task that exits (normally
  or via crash) is **not** restarted. We don't want a transient
  API outage to put us in a hot retry loop; the periodic
  schedulers handle eventual recovery, and a dev can re-run any
  step manually from IEx.
  """

  use Task, restart: :temporary

  require Logger

  alias EftBuddy.Sync.Reporter

  @lock_id {__MODULE__, :running}

  # Hold this long after boot before the cold-start sync begins, giving the
  # app time to finish coming up (Endpoint serving, supervision tree settled)
  # before we start hitting the Tarkov.dev / wiki APIs. Bootstrap is a
  # separate Task, so this wait never blocks the rest of startup — the
  # Endpoint is already serving during it, which is exactly the "everything
  # still loading" window the browse pages' standby state is built for.
  #
  # Overridable at runtime via `config :eft_buddy, :bootstrap_startup_delay_ms,
  # <ms>` so you can lengthen the window to eyeball that loading state on a
  # fresh DB (bump it in dev; leave it at the default in prod). Defaults to 15s.
  @default_startup_delay_ms :timer.seconds(15)

  defp startup_delay_ms,
    do: Application.get_env(:eft_buddy, :bootstrap_startup_delay_ms, @default_startup_delay_ms)

  # ── Supervisor entrypoint ──────────────────────────────

  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  # ── Public API ─────────────────────────────────────────

  @doc """
  Run the cold-start sync sequence. Idempotent — every step is
  driven by a syncer that's itself idempotent (`upsert_all` plus
  `cleanup_stale`), so a manual re-run is safe.

  Returns `:ok` after the sequence finishes (regardless of which
  individual steps succeeded), or `:skipped` if another node
  already holds the cluster-wide bootstrap lock.
  """
  def run do
    nodes = [node() | Node.list()]

    case :global.set_lock(@lock_id, nodes, 0) do
      true ->
        # Hold warming until the whole sequence is done. The steps below are
        # MINUTES apart, so the warmer's five-second debounce collapses nothing:
        # each `:stop` event triggers its own batch, and the item catalogue —
        # owned by five of these feeds — gets rebuilt four times, three of them
        # against data the next step is about to overwrite.
        #
        # Suspension only stops the flush; source names still accumulate, so
        # `resume/0` warms the union exactly once. It is in the `after` block
        # with the lock release because a warmer left suspended by a crashed
        # cold start would be permanently off. (`EftBuddy.Cache.Warmer` also
        # self-resumes on a deadline, for the case this process is killed
        # outright and never reaches the `after` at all.)
        EftBuddy.Cache.Warmer.suspend()

        try do
          do_run()
        after
          EftBuddy.Cache.Warmer.resume()
          :global.del_lock(@lock_id, nodes)
        end

      false ->
        Logger.info(
          "[#{prefix()}] Another node already runs cold-start; staying idle on this node."
        )

        :skipped
    end
  end

  # ── Sequence ───────────────────────────────────────────

  defp do_run do
    delay_ms = startup_delay_ms()

    Logger.info("[#{prefix()}] Boot complete; cold-start sync starts in #{fmt_time(delay_ms)}.")

    Process.sleep(delay_ms)

    started_at = System.monotonic_time()
    Logger.info("[#{prefix()}] Cold-start sync sequence starting…")

    # The sequence and its ordering live in `EftBuddy.Sync.Registry`, not here.
    # It used to be a hardcoded list in this function and another hardcoded list
    # in `notify_schedulers/0`, and the two had already diverged.
    #
    # The order is the FK graph rather than a preference. Items is the root.
    # Everything after it either resolves against items or seeds something that
    # does, and each step only DROPS the item-keyed slices it cannot resolve
    # (writing useful rows regardless), so a failed Items step degrades the
    # sequence rather than invalidating it.
    #
    # `requires_items` marks the exception: a step whose every parent FK resolves
    # against items would fetch its whole set from the API only to sanitise all
    # of it away — see the "no resolvable barters/crafts" self-skip. Skipping it
    # up front avoids hammering an already-struggling upstream for data that
    # cannot be used; the feed's own timer populates it once items are back.
    #
    # Each step populates BOTH game modes where they diverge: per-mode
    # `item_prices` and vendor prices, the regular and pve quest graphs, barters
    # for both modes. Maps, hideout and item entities are identical across modes.
    notified = run_cold_start_steps()

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    Logger.info("[#{prefix()}] Cold-start sync sequence complete in #{fmt_time(elapsed_ms)}.")

    # Each feed was released as its own step succeeded, so there is nothing left to
    # cast here. What remains is to say out loud which feeds were NOT released —
    # see `report_unnotified/1`.
    report_unnotified(notified)

    :ok
  end

  # Run each registered cold-start step in order, carrying forward the outcomes
  # of the steps that later ones depend on.
  @doc false
  # Takes the step list so a test can prove the RELEASE TIMING — that a feed is
  # cast to while later steps are still running — without driving the real feeds
  # through the network. Ordering is the whole point of this function, and it
  # cannot be asserted from the registry's shape alone.
  def run_cold_start_steps(steps \\ EftBuddy.Sync.Registry.cold_start_steps()) do
    steps
    |> Enum.reduce({%{}, []}, fn step_spec, {outcomes, notified} ->
      required = Map.get(step_spec, :requires)

      if required && not step_succeeded?(Map.get(outcomes, required)) do
        Logger.warning(
          "[#{prefix()}] #{step_spec.label}: skipped — upstream dependency #{required} " <>
            "failed, so every FK this step resolves would be unresolvable"
        )

        {outcomes, notified}
      else
        result = step(step_spec.label, step_spec.run)

        outcomes =
          case Map.get(step_spec, :key) do
            nil -> outcomes
            key -> Map.put(outcomes, key, result)
          end

        {outcomes, notify_step(step_spec, result, notified)}
      end
    end)
    |> elem(1)
  end

  # Release a feed the moment ITS step succeeds, rather than waiting for the rest
  # of the sequence.
  #
  # The cast means "you have run; anchor your recurring timer from here", so the
  # honest moment to send it is when this feed's work finished — not when every
  # other feed's did. Sending it at the end was fine while the sequence took
  # seconds. Once the Fandom scrapes joined it, the sequence began to outlast the
  # SHORTEST fallback in the registry, and a fallback exists to mean "Bootstrap
  # died" — so "Bootstrap is slow" became indistinguishable from it.
  #
  # `EftBuddy.Chapters.Sync` is the one that proved it: a zero stagger puts its
  # step early in the Fandom group and its fallback 15 minutes out, so it sat idle
  # holding no lock while the events scrape ran for thirteen minutes, then
  # re-scraped all eleven pages it had just written. Idempotent and lock-guarded,
  # so nothing was corrupted — it just doubled the load on a rate-limited third
  # party during the window that party is already being hammered.
  #
  # Only a clean `{:ok, _}` releases a feed. A step that failed or skipped wrote
  # nothing, which is exactly the state the short fallback is for: it should retry
  # in minutes, not arm a full interval out and leave its table empty until
  # tomorrow.
  defp notify_step(step_spec, result, notified) do
    with mod when not is_nil(mod) <- Map.get(step_spec, :notify),
         true <- step_succeeded?(result) do
      GenServer.cast({:global, mod}, :bootstrap_complete)
      [mod | notified]
    else
      _ -> notified
    end
  end

  # Name the feeds the sequence did NOT release, because they are now running on
  # their fallback timers and nothing else says so.
  #
  # A feed here is not broken: its fallback is short by design, so it retries in
  # minutes. But "released, on its normal cadence" and "failed, retrying shortly"
  # are different states and used to be indistinguishable — the blanket
  # end-of-sequence cast released every feed regardless of whether its step had
  # worked, which meant a feed whose cold start failed armed a FULL interval out
  # and served an empty table until tomorrow.
  #
  # `:info` when the list is empty, `:warning` when it is not: on a healthy boot
  # this line is the confirmation that every feed is anchored, and on an unhealthy
  # one it is the list of what to look at.
  defp report_unnotified(notified) do
    case EftBuddy.Sync.Registry.notifiable() -- notified do
      [] ->
        Logger.info("[#{prefix()}] All #{length(notified)} feeds released on their own cadence.")

      stranded ->
        Logger.warning(
          "[#{prefix()}] #{length(stranded)} feed(s) not released — their cold-start step did " <>
            "not succeed, so they stay on their short fallback timers rather than a full " <>
            "interval: #{stranded |> Enum.map(&inspect/1) |> Enum.join(", ")}"
        )
    end
  end

  # `[Bootstrap]` is the same on every line, so cache the
  # colorized version once per call. `colorize_label/1` is
  # cheap, but doing the lookup in every Logger.info call
  # makes the call sites noisier than they need to be.
  defp prefix, do: Reporter.colorize_label("Bootstrap")

  defp fmt_time(ms) when ms >= 1_000,
    do: "#{:erlang.float_to_binary(ms / 1000, decimals: 2)}s"

  defp fmt_time(ms), do: "#{ms}ms"

  # Run a single phase, normalise its return into a single log
  # line, and contain crashes so a downstream phase still gets a
  # chance to run. The per-module Reporter summary line
  # (`[ItemsSync] ok in 12.42s — …`) prints just before each of
  # these `[Bootstrap] X: ok` lines, so we deliberately don't
  # duplicate the module-name coloring here — `[Bootstrap]` alone
  # is enough to mark the orchestration line, and the Reporter
  # line above it carries the per-module color.
  defp step(label, fun) do
    Logger.info("[#{prefix()}] Running: #{label}")

    result =
      try do
        fun.()
      rescue
        e ->
          Logger.error(
            "[#{prefix()}] #{label} crashed: #{Exception.message(e)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          {:error, {:crash, Exception.message(e)}}
      end

    log_step_result(label, result)
    result
  end

  defp log_step_result(label, {:ok, summary}),
    do: Logger.info("[#{prefix()}] #{label}: ok #{inspect(summary)}")

  defp log_step_result(label, {:error, :already_running}),
    do: Logger.info("[#{prefix()}] #{label}: skipped — another sync is already running")

  # `{:skip, reason}` is part of the `EftBuddy.Sync.Scheduler.do_run/0` contract —
  # `EftBuddy.Items.Sync.run_barters_and_crafts/0` returns it when the traders its
  # FKs resolve against are not in the database yet — but this function had no
  # clause for it, so a legitimate, expected outcome logged as "unexpected
  # return". A log line that cries wolf on a normal cold start is worse than none.
  defp log_step_result(label, {:skip, reason}),
    do: Logger.info("[#{prefix()}] #{label}: skipped — #{Reporter.describe_error(reason)}")

  # A step that committed some of its work and failed the rest (currently
  # only Tasks, per game mode). It's not a clean failure — surface it as a
  # warning with a per-mode breakdown rather than a scary `error`/`failed`.
  defp log_step_result(label, {:error, {:partial, _ok, _failures} = partial}) do
    Logger.warning("[#{prefix()}] #{label}: partial — #{Reporter.describe_error(partial)}")

    Logger.debug(fn ->
      "[#{prefix()}] #{label}: detail — #{inspect(partial, pretty: true)}"
    end)
  end

  defp log_step_result(label, {:error, reason}) do
    # Keep the headline line short and human-readable — a raw `inspect/1`
    # of an upstream error (e.g. the ~15-key Cloudflare 1102 map) drowns
    # the surrounding lines. The full term is still emitted at :debug for
    # anyone chasing a ray_id / instance id.
    Logger.error("[#{prefix()}] #{label}: failed — #{Reporter.describe_error(reason)}")

    Logger.debug(fn ->
      "[#{prefix()}] #{label}: failure detail — #{inspect(reason, pretty: true)}"
    end)
  end

  defp log_step_result(label, other),
    do: Logger.warning("[#{prefix()}] #{label}: unexpected return #{inspect(other)}")

  # Only a clean `{:ok, _}` clears a dependent step to run. An
  # `:already_running` means another full sync already holds the lock and
  # will drive barters/crafts itself, so skipping here is correct too.
  defp step_succeeded?({:ok, _}), do: true
  defp step_succeeded?(_), do: false
end
