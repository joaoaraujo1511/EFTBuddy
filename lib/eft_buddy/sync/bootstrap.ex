defmodule EftBuddy.Sync.Bootstrap do
  @moduledoc """
  One-shot, supervised orchestrator that runs the cold-start sync
  sequence on application boot, in strict dependency order:

      1. `EftBuddy.Items.Sync.run_items/0`
         items + categories + vendors + prices

      2. `EftBuddy.Maps.Sync.run/0`
         maps + bosses + extracts + transits + locks + hazards +
         access keys + spawns + stationary weapons + loot
         containers. Item-gated extracts, lock keys and access
         keys resolve their FKs against the items from step 1.
         Runs before Tasks so `tasks.map_id` resolves against the
         full (rich) map set, and so the Maps sync (not the Tasks
         sync) owns the `maps` table lifecycle.

      3. `EftBuddy.Hideout.Sync.run/0`
         stations + levels + traders + skills (item-requirement
         FKs resolve against the items written in step 1)

      4. `EftBuddy.Tasks.Sync.run/0`
         tasks + objectives + unlocks (FKs resolve against the
         items from step 1 and the maps from step 2). Also seeds
         the task-only traders — Ref, Fence, Lightkeeper — which
         never appear in the hideout data but *are* referenced by
         barters in step 5.

      5. `EftBuddy.Items.Sync.run_barters_and_crafts/0`
         barters + crafts. Their parent FKs need the items from
         step 1, the station_levels from step 3, and the full
         trader set from steps 3–4 (without Ref et al., every Ref
         barter is dropped by `sanitize_barters/3`). Running this
         after Tasks also lets each barter/craft resolve its
         `task_unlock` against the tasks written in step 4.

  Bootstrap is what runs the five wipe-scale syncs *first*, in the FK
  order above. It is not what keeps them running: each of them is
  also a GenServer with its own timer, and devs can re-run any on
  demand from IEx:

      EftBuddy.Maps.Sync.run()
      EftBuddy.Hideout.Sync.run()
      EftBuddy.Tasks.Sync.run()

  When the sequence completes, Bootstrap casts `:bootstrap_complete`
  to every scheduler (`notify_schedulers/0`). The message means two
  different things depending on who receives it:

    * `EftBuddy.Chapters.Sync` and `EftBuddy.Events.Sync` have NOT
      run yet — Bootstrap merely releases them — so they arm their
      first run at a small offset from that moment (chapters
      immediately, events +1 min). `EftBuddy.Wiki.Sync` is not kicked
      here: it chains off the events sync's completion, since it
      needs that run's `event_quests` blacklist. So the three never
      scrape the Fandom wiki concurrently.

    * `Maps`, `Hideout`, `Ammo`, `Armor` and `Tasks` HAVE just run,
      here in `do_run/0`. They therefore arm their first *recurring*
      run a full interval plus their own stagger away (maps +20 min,
      hideout +30, ammo +40, armor +50, tasks +60), which spaces them
      across the day and preserves this module's FK ordering within
      each cycle. Tasks ticks every 12h, the rest daily.

  Each also keeps a shorter fallback timer in case the cast never
  arrives — for the five that fallback is the recovery path when
  Bootstrap itself failed, since it means they have never run at all.

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
        try do
          do_run()
        after
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

    # Each step below now populates BOTH game modes where they diverge:
    # `run_items/0` also syncs the per-mode `item_prices` + vendor prices
    # for regular and pve; `Tasks.Sync.run/0` syncs the regular and pve
    # quest graphs; `run_barters_and_crafts/0` syncs barters for both
    # modes (crafts are identical across modes, so they stay single-set).
    # Maps, hideout and item entities are identical across modes and need
    # no per-mode handling. The FK ordering is unchanged.
    # Items is the FK root for everything below. Maps, Hideout and Tasks
    # only *drop* the item-keyed slices they can't resolve (and otherwise
    # write useful rows), so they run regardless of whether Items
    # succeeded. Barters & crafts are different: every parent FK resolves
    # against the items from step 1, so with no items the step fetches the
    # full barter/craft set from the API only to sanitise all of it away —
    # see the "no resolvable barters/crafts" self-skip. When Items failed
    # we skip that step up front rather than hammering an already-struggling
    # upstream for data we can't use; the recurring Items scheduler will
    # populate barters/crafts on a later tick once items are back.
    items_result = step("Items (items + prices)", &EftBuddy.Items.Sync.run_items/0)
    step("Maps", &EftBuddy.Maps.Sync.run/0)
    # Ammo ballistics link back to items (ammo.item_id) for name / icon /
    # availability, so this runs after Items. Like Maps it only drops the
    # item-keyed link it can't resolve (leaving item_id null) and otherwise
    # writes useful ballistics rows, so it runs regardless of step 1's
    # outcome.
    step("Ammo", &EftBuddy.Ammo.Sync.run/0)
    # Armor plates also link back to items (armor_plates.item_id) for
    # name / icon / price, so this runs after Items alongside Ammo.
    step("Armor", &EftBuddy.Armor.Sync.run/0)
    step("Hideout", &EftBuddy.Hideout.Sync.run/0)
    step("Tasks", &EftBuddy.Tasks.Sync.run/0)

    if step_succeeded?(items_result) do
      step("Items (barters & crafts)", &EftBuddy.Items.Sync.run_barters_and_crafts/0)
    else
      Logger.warning(
        "[#{prefix()}] Items (barters & crafts): skipped — upstream dependency " <>
          "'Items (items + prices)' failed, so every barter/craft FK would be unresolvable"
      )
    end

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

  # Cast to the cluster-wide singletons; if one isn't registered (e.g. cold
  # start disabled), the cast is a harmless no-op.
  #
  # Two groups, and they mean OPPOSITE things by the same message:
  #
  #   * The wiki scrapers have NOT run yet — Bootstrap only releases them — so
  #     they arm their first run at a small offset (chapters immediately, events
  #     +1 min). `EftBuddy.Wiki.Sync` is deliberately absent: it chains off
  #     `EftBuddy.Events.Sync` completion, because it needs that run's
  #     `event_quests` blacklist.
  #
  #   * The five wipe-scale syncs HAVE just run, right here in `do_run/0`. They
  #     arm their first recurring run a full interval plus their stagger away,
  #     so this cast schedules them rather than triggering them. Each module's
  #     `@bootstrap_offset` says so at the definition.
  defp notify_schedulers do
    scrapers = [EftBuddy.Chapters.Sync, EftBuddy.Events.Sync]

    periodic = [
      EftBuddy.Maps.Sync,
      EftBuddy.Hideout.Sync,
      EftBuddy.Ammo.Sync,
      EftBuddy.Armor.Sync,
      EftBuddy.Tasks.Sync
    ]

    for mod <- scrapers ++ periodic do
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
