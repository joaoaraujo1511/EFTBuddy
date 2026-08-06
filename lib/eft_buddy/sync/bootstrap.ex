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

  When the sequence finishes, Bootstrap casts `:bootstrap_complete` to every feed
  `EftBuddy.Sync.Registry.notifiable/0` names. One message, two meanings, which
  is why each module declares a `bootstrap_mode/0`:

    * `:released` — the feed has NOT run. Bootstrap is letting it start, so it
      arms at its stagger. The Fandom scrapes are these, spaced so they never hit
      the wiki concurrently.

    * `:ran` — the feed HAS just run, here in `do_run/0`. It arms its first
      *recurring* run a full interval plus its stagger away, which spaces the
      feeds across the cycle and preserves the FK ordering within each one.

  `EftBuddy.Wiki.Sync` is `:chained` and receives nothing here: it is armed by
  `EftBuddy.Events.Sync` completing, because it reads that run's `event_quests`
  blacklist.

  Every feed also keeps a shorter fallback timer for the case where the cast
  never arrives — which, for a `:ran` feed, means Bootstrap failed and it has
  never run at all.

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
    run_cold_start_steps()

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    Logger.info("[#{prefix()}] Cold-start sync sequence complete in #{fmt_time(elapsed_ms)}.")

    # The cold-start data the wiki scrapers depend on (the tasks table the
    # quest matcher and the event-quest matcher read) is now in place, so
    # release them. Chapters and events stagger themselves from here
    # (chapters immediately, events at +1 min); the quest scrape isn't kicked
    # here — it chains off the events scrape's completion (it needs that run's
    # `event_quests` blacklist), so the events sync signals it when it
    # finishes. None of them ever hit the Fandom API concurrently.
    #
    # The same signal also anchors the five wipe-scale syncs' recurring timers —
    # see `notify_schedulers/0`.
    notify_schedulers()

    :ok
  end

  # Run each registered cold-start step in order, carrying forward the outcomes
  # of the steps that later ones depend on.
  defp run_cold_start_steps do
    Enum.reduce(EftBuddy.Sync.Registry.cold_start_steps(), %{}, fn step_spec, outcomes ->
      required = Map.get(step_spec, :requires)

      if required && not step_succeeded?(Map.get(outcomes, required)) do
        Logger.warning(
          "[#{prefix()}] #{step_spec.label}: skipped — upstream dependency #{required} " <>
            "failed, so every FK this step resolves would be unresolvable"
        )

        outcomes
      else
        result = step(step_spec.label, step_spec.run)

        case Map.get(step_spec, :key) do
          nil -> outcomes
          key -> Map.put(outcomes, key, result)
        end
      end
    end)
  end

  # Cast to the cluster-wide singletons; if one isn't registered (e.g. cold
  # start disabled), the cast is a harmless no-op.
  #
  # The recipients come from `EftBuddy.Sync.Registry.notifiable/0` rather than a
  # list maintained here. That list had gone out of step: `EftBuddy.Items.Sync`
  # was missing from it, so it never received the cast and armed its first run
  # from `init/1` instead of from the end of the cold start — drifting from boot
  # forever, with nothing logged and nothing failing.
  #
  # One message, two meanings, which is why `bootstrap_mode/0` names them:
  #
  #   * `:released` — the feed has NOT run. Bootstrap is letting it start, so it
  #     arms at its stagger. The Fandom scrapes are these.
  #
  #   * `:ran` — the feed HAS just run, right here in `do_run/0`. It arms its
  #     first RECURRING run a full interval plus stagger away, so the cast
  #     schedules it rather than triggering it.
  #
  # `:chained` feeds are absent by construction: `EftBuddy.Wiki.Sync` is armed by
  # `EftBuddy.Events.Sync` completing, because it reads that run's `event_quests`
  # blacklist.
  defp notify_schedulers do
    for mod <- EftBuddy.Sync.Registry.notifiable() do
      GenServer.cast({:global, mod}, :bootstrap_complete)
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
