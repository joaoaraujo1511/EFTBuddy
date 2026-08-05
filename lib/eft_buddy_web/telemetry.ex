defmodule EftBuddyWeb.Telemetry do
  @moduledoc """
  Metric definitions and the periodic measurements that feed them.

  ## Where the metrics actually go — and where they DON'T

  **In development:** `Phoenix.LiveDashboard` consumes `metrics/0` directly and
  charts everything defined below. It is mounted at `/dev/dashboard` inside the
  `:dev_routes` guard in `EftBuddyWeb.Router`.

  **In production: nowhere.** Be clear about this rather than discovering it during
  an incident. The dashboard used to be mounted in prod as well, behind a
  hand-written fail-closed basic-auth plug. That plug and its route were removed
  deliberately — an authenticated admin surface on the public internet was judged
  a risk not worth carrying for a single-operator project at launch. The route now
  ceases to exist when `:dev_routes` is unset, which is a stronger guarantee than
  any gate in front of it, and the trade was made with the cost understood:

    * `/health` and `/health/sync` are the ENTIRE production observability story.
    * Every metric below is defined, emitted, and consumed by nothing in prod.
    * The polled gauges are the sharpest loss, because the failure modes they
      exist for — a sync that stops, sessions approaching the ceiling — are
      exactly the ones nothing else can see. `/health/sync` still covers the
      first; nothing covers the second.

  Keep the definitions anyway. They cost nothing at runtime when unconsumed, they
  are correct, and whatever reporter arrives later (a hosted metrics backend, a
  scrape endpoint) plugs into `metrics/0` unchanged.

  The generator's `{Telemetry.Metrics.ConsoleReporter, metrics: metrics()}` line is
  **deliberately not** the answer to that gap. `ConsoleReporter` logs a line per
  metric per event, and the list below includes a `summary` on
  `phoenix.router_dispatch.stop.duration` — i.e. a log line on every single HTTP
  request, in production, forever. That is not observability, it is a
  denial-of-service against your own log budget.

  A scrape-based reporter (`telemetry_metrics_prometheus_core` plus a `/metrics`
  route) is the right shape when there is a Prometheus to scrape it. There is not
  yet: this is a single node with no metrics backend and a free-first hosting
  budget. Revisit when that changes — and prefer it to re-mounting a dashboard.

  ## What the polled measurements are for

  Event-driven metrics can only describe things that *happen*. The two failure
  modes this app actually has are things that **stop** happening or **quietly
  accumulate**, and neither emits an event:

    * a sync that has stopped running emits nothing at all, so its staleness is
      invisible to `[:eft_buddy, :sync, :stop]` — age has to be polled
      (`Sync.Reporter.emit_freshness/0`);
    * operator sessions approach the `max_children` ceiling silently, after which
      every new visitor degrades to cookie-only state while the site keeps
      answering 200 (`OperatorSessions.emit_telemetry/0`).
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # `:telemetry_poller`'s own default poller supplies the `vm.*` measurements;
      # these are the app-specific ones. 10s is well below the resolution of
      # anything measured here and costs one ETS scan plus a supervisor count.
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("eft_buddy.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("eft_buddy.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("eft_buddy.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("eft_buddy.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("eft_buddy.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Background sync metrics (emitted by EftBuddy.Sync.Reporter).
      # Tagged by sync label (ItemsSync, PricesSync, TasksSync, ...) and
      # outcome (ok/error) so a failing or slow sync is visible in
      # LiveDashboard / any attached reporter.
      summary("eft_buddy.sync.stop.duration_ms",
        tags: [:label, :outcome],
        description: "Wall-clock duration of a sync run"
      ),
      last_value("eft_buddy.sync.stop.errors",
        tags: [:label, :outcome],
        description: "Query errors recorded during the run"
      ),

      # POLLED. The gauge that answers "is anything stale?" — see the moduledoc on
      # why a stopped sync cannot be detected from its own events.
      last_value("eft_buddy.sync.freshness.seconds_since_run",
        tags: [:label, :outcome],
        description: "Age of each sync's last run. Climbs forever if a sync stops."
      ),

      # POLLED. Headroom against the `max_children` backstop in `application.ex`.
      # Past the ceiling every new visitor silently degrades to cookie-only state.
      last_value("eft_buddy.operator_sessions.count",
        description: "Live operator sessions"
      ),
      last_value("eft_buddy.operator_sessions.ceiling",
        description: "max_children ceiling the count is measured against"
      ),

      # A progress slice arriving over the size ceiling is DROPPED
      # (`EftBuddy.Progress`), which is exactly the shape of bug that hides as
      # "some users say their progress vanished". Counting it makes it answerable.
      counter("eft_buddy.progress.slice_rejected.bytes",
        tags: [:mode],
        description: "Progress slices refused for exceeding the per-mode size ceiling"
      ),

      # POLLED. The read cache's own health. The failure worth catching is not a
      # crash but a collapse: a cache whose hit rate has gone to zero is paying
      # a lookup on every read, carrying every staleness risk, and saving
      # nothing — and it looks completely normal from the outside. An entry
      # count pinned at zero after a sync means invalidation fires and warming
      # does not. See `EftBuddy.Cache.emit_telemetry/0`.
      last_value("eft_buddy.cache.state.entries",
        description: "Live cache entries"
      ),
      last_value("eft_buddy.cache.state.hit_rate_percent",
        description: "Share of VISITOR reads served from memory since boot"
      ),
      last_value("eft_buddy.cache.state.memory_bytes",
        unit: {:byte, :kilobyte},
        description: "Memory the cache table occupies"
      ),
      last_value("eft_buddy.cache.state.warm_entries",
        description: "Entries written by the warmer rather than by a request"
      ),

      # The metric that catches the failure the others cannot express. Entry
      # count, memory and hit rate can all look healthy while most of the warm
      # registry has quietly expired — this is "how many of the reads that are
      # supposed to be precomputed actually are".
      last_value("eft_buddy.cache.warm.state.specs_live",
        description: "Warm specs currently live"
      ),
      last_value("eft_buddy.cache.warm.state.specs_total",
        description: "Warm specs registered"
      ),

      # How much a finishing sync actually dropped. Zero entries dropped by a
      # sync that owns entries is the signature of a source name that no longer
      # matches anything — a rename away from silently serving stale data.
      last_value("eft_buddy.cache.invalidated.entries",
        tags: [:source],
        description: "Entries dropped when a syncer finished"
      ),
      summary("eft_buddy.cache.warm.duration_ms",
        tags: [:label, :outcome],
        description: "Time spent rebuilding a cache entry ahead of any request"
      ),

      # A refused prune is `Sync.Helpers.cleanup_safe?/3` catching a truncated
      # upstream response — the single most destructive failure mode in the app
      # announcing itself. It must never be a thing you only find in logs.
      counter("eft_buddy.sync.cleanup_refused.current_count",
        tags: [:label],
        description: "Destructive prunes refused by the cleanup guard"
      )
    ]
  end

  @doc false
  # Public only so a test can call every entry for real. A poller measurement that
  # raises is dropped with a log line nobody reads, so the gauge simply never
  # appears — indistinguishable from a metric that is merely quiet.
  def periodic_measurements do
    [
      {EftBuddy.Sync.Reporter, :emit_freshness, []},
      {EftBuddy.OperatorSessions, :emit_telemetry, []},
      {EftBuddy.Cache, :emit_telemetry, []},
      # Separate from `Cache.emit_telemetry/0` rather than folded into it:
      # coverage is the WARMER's knowledge (it owns the registry), and computing
      # it inside the cache would invert the dependency for a dashboard
      # convenience.
      {EftBuddy.Cache.Warmer, :emit_telemetry, []}
    ]
  end
end
