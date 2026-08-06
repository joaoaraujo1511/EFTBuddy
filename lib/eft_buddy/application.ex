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
      # Rebuilds cache entries as soon as the syncer that owns them finishes, so
      # the server absorbs every cold read instead of the next visitor. Attaches
      # its OWN telemetry handler, separate from the cache's invalidation one, so
      # that a failing warm can never detach the handler that keeps the cache
      # honest — see `EftBuddy.Cache.Warmer`.
      EftBuddy.Cache.Warmer,
      # Owns the in-memory item catalogue's ETS tables. Inert until
      # `ITEM_DATASET=1` — see `EftBuddy.Items.Dataset` — and every read through
      # it falls back to SQL when it is not ready, so an unbuilt or stale
      # dataset costs latency rather than correctness.
      EftBuddy.Items.Dataset,
      # Every background feed, from `EftBuddy.Sync.Registry` rather than listed
      # here. One list rather than three: the supervision children, the
      # cold-start order and the set that receives `:bootstrap_complete` used to
      # be maintained separately, and `Items.Sync` had gone missing from the
      # third — so it silently drifted from boot instead of anchoring to the end
      # of the cold start. `registry_test.exs` now asserts every
      # `lib/eft_buddy/**/sync.ex` module is registered.
      #
      # Started BEFORE `Sync.Bootstrap` below so its completion casts land on
      # running processes.
      if(start_sync?, do: EftBuddy.Sync.Registry.children(), else: []),
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
      # One-shot orchestrator for the cold-start sync sequence, running each
      # feed's synchronous `run/0` in the dependency order
      # `EftBuddy.Sync.Registry.cold_start_steps/0` declares. Restart strategy is
      # `:temporary` so a Task crash doesn't cycle the supervision tree — every
      # feed's own timer recovers it on the next tick.
      #
      # LAST of the sync group, so every scheduler it casts to is already up.
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

    # Flattened because the registry contributes a LIST of feeds in one slot;
    # child specs are tuples or atoms, so nothing else here is affected. Then the
    # `nil`s from the `start_sync?` gates are dropped — in test that flag is
    # false, so every sync child is absent rather than started and idle.
    children = children |> List.flatten() |> Enum.reject(&is_nil/1)

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
