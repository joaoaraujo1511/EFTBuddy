defmodule EftBuddy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach the sync-reporter telemetry handler before any code
    # can issue a query so we don't lose events from early callers.
    EftBuddy.Sync.Reporter.attach_telemetry()

    # Allocate the bug-report rate limiter's counter. Done here so the one
    # `:persistent_term` write happens at boot rather than racing on the first
    # submission — see `EftBuddy.Feedback` for why the counter itself is
    # `:atomics` and not a persistent term.
    EftBuddy.Feedback.init_rate_limiter()

    # The background data sync (periodic Items.Sync + the cold-start
    # Bootstrap) is disabled in test (see config/test.exs) so the suite
    # never hits the live Tarkov.dev API or races the Ecto SQL sandbox.
    start_sync? = Application.get_env(:eft_buddy, :start_sync, true)

    children = [
      EftBuddyWeb.Telemetry,
      EftBuddy.Repo,
      # Read cache for sync-populated data. BEFORE the syncers below, because it
      # attaches the telemetry handler that drops entries when a sync finishes —
      # a syncer completing before that handler exists would leave stale entries
      # with nothing but their TTL to clear them. See `EftBuddy.Cache`.
      EftBuddy.Cache,
      # Items.Sync runs two cadences: a frequent lightweight price refresh and
      # an infrequent full pipeline (items + barters + crafts).
      if(start_sync?, do: EftBuddy.Items.Sync),
      # The wipe-scale feeds. Each is run ONCE at boot by
      # `EftBuddy.Sync.Bootstrap`, in FK order, and then re-run by its own timer
      # on a staggered daily cycle (tasks twice-daily) — maps +20 min, hideout
      # +30, ammo +40, armor +50, tasks +60 from bootstrap completion.
      #
      # They used to have no timer at all, on the reasoning that "hideout and
      # tasks data only change on patches / wipes". True, but it made data
      # correctness a function of DEPLOY cadence: a node up across a wipe served
      # the previous wipe's quest graph, hideout requirements and ballistics
      # indefinitely, and `/health/sync` could not report it — a feed with no
      # recurring timer cannot be judged on age, so `EftBuddy.Sync.Freshness`
      # correctly exempted all five from staleness. The exemption was right; the
      # missing cadence was the defect.
      if(start_sync?, do: EftBuddy.Maps.Sync),
      if(start_sync?, do: EftBuddy.Hideout.Sync),
      if(start_sync?, do: EftBuddy.Ammo.Sync),
      if(start_sync?, do: EftBuddy.Armor.Sync),
      if(start_sync?, do: EftBuddy.Tasks.Sync),
      {DNSCluster, query: Application.get_env(:eft_buddy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: EftBuddy.PubSub},
      # Per-operator live state (HUD prefs + progress), authoritative for the
      # lifetime of a connection so a LiveView navigation never renders the
      # stale connect-time snapshot. Registry resolves a token to its session
      # process; the DynamicSupervisor owns them. Must start BEFORE the
      # Endpoint, since the first request can create a session.
      # See `EftBuddy.OperatorSessions`.
      {Registry, keys: :unique, name: EftBuddy.OperatorSessions.Registry},
      # `max_children` is a backstop against unbounded growth on a public,
      # account-free site. Sessions are only ever created from a *connected*
      # mount (so a crawler GET allocates nothing) and shut down when idle, but
      # past this ceiling callers degrade to cookie-only state rather than
      # exhausting the node.
      #
      # The value and the arithmetic behind it live in `OperatorSessions.ceiling/0`,
      # NOT here: `stats/0` reports headroom against the same number, and the two
      # used to hold separate copies of the literal. Do not inline it back.
      {DynamicSupervisor,
       name: EftBuddy.OperatorSessions.Supervisor,
       strategy: :one_for_one,
       max_children: EftBuddy.OperatorSessions.ceiling()},
      # Scrapes quest walkthroughs from the EFT Fandom wiki into the
      # `wiki_quests` table (replacing the old committed JSON manifests +
      # boot-time ETS load). Gated on `start_sync?` like the other
      # syncers so the test suite never hits the wiki. Runs LAST of the
      # three wiki scrapers: it's chained off `EftBuddy.Events.Sync`
      # completion (it reads that run's freshly-written `event_quests`
      # blacklist, so it must run after it) rather than on a fixed offset,
      # which also keeps the two heaviest scrapes off the Fandom API at
      # once. Then follows each daily events run (with a fallback timer).
      if(start_sync?, do: EftBuddy.Wiki.Sync),
      # Scrapes storyline-chapter walkthroughs from the EFT Fandom wiki
      # into the `wiki_chapters` table (replacing the old committed JSON
      # manifests under priv/static/storyline-dump/ + boot-time ETS
      # load). Gated on `start_sync?` like the other syncers so the test
      # suite never hits the wiki. Released by `EftBuddy.Sync.Bootstrap`
      # when the cold start finishes and runs FIRST of the three wiki
      # scrapers (immediately — no DB dependency, smallest set), then daily.
      if(start_sync?, do: EftBuddy.Chapters.Sync),
      # Scrapes the EFT Fandom "Events" page (and each event quest's own
      # page) into the `events` / `event_quests` tables, powering the
      # Events tab. Gated on `start_sync?` like the other syncers so the
      # test suite never hits the wiki. Released by `EftBuddy.Sync.Bootstrap`
      # when the cold start finishes and runs SECOND (+1 min after the
      # chapter scrape, so the two don't overlap, and after the tasks table
      # is populated): the quest sync (+8 min) reads this run's
      # `event_quests` rows to blacklist event quests from its own scrape,
      # keeping them out of the Tasks-tab WIP list. Then daily.
      if(start_sync?, do: EftBuddy.Events.Sync),
      # One-shot orchestrator for the cold-start sync sequence.
      # Calls each syncer's synchronous `run/0` (or `run_items/0`
      # / `run_barters_and_crafts/0`) in dependency order:
      # Items → Hideout → Tasks → Items barters/crafts. Restart
      # strategy is `:temporary` so a Task crash doesn't cycle
      # the supervision tree — for hideout / tasks recovery is
      # manual, and `Items.Sync`'s periodic tick refreshes items.
      if(start_sync?, do: EftBuddy.Sync.Bootstrap),
      # Start a worker by calling: EftBuddy.Worker.start_link(arg)
      # {EftBuddy.Worker, arg},
      # Start to serve requests, typically the last entry
      EftBuddyWeb.Endpoint,
      # The operator dashboard, on its own loopback-published port. Absent
      # `:admin_dashboard` this is `nil` and gets rejected below, so the endpoint
      # is not merely unrouted — it is never started and binds nothing.
      # `config/runtime.exs` sets the key only when ADMIN_DASHBOARD_PORT is
      # present. See `EftBuddyWeb.AdminEndpoint` for the threat model.
      if(Application.get_env(:eft_buddy, :admin_dashboard, false),
        do: EftBuddyWeb.AdminEndpoint
      )
    ]

    # In test, `start_sync?` is false, so the gated children above are
    # `nil` — drop them before handing the list to the supervisor.
    children = Enum.reject(children, &is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EftBuddy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EftBuddyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
