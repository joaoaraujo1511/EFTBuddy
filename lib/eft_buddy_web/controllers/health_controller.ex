defmodule EftBuddyWeb.HealthController do
  @moduledoc """
  Two probes, deliberately separate, because they answer different questions and
  conflating them made both useless.

  ## `GET /health` (and `/healthz`) — LIVENESS

  "Is this process able to serve requests at all?" Database reachability and nothing
  else. `200` when it is, `503` when it isn't.

  This is what a load balancer and an uptime monitor should watch. It must **not**
  go red on stale data: pulling the only instance out of rotation because a wiki
  scrape is a day late would turn a cosmetic problem into an outage.

  ## `GET /health/sync` — READINESS

  "Is the data this instance serves actually fresh?" `200` when every feed is inside
  its budget, `503` when one has stopped, gone stale, or failed. See
  `EftBuddy.Sync.Freshness`.

  This is the probe that exists because of the app's most dangerous property: there
  is no user-authored content, so a sync that stops or truncates does not produce an
  error — the pages keep rendering and quietly present stale or missing game data as
  fact. Nothing else in the system can detect that.

  ## Why liveness was previously blind

  `/health` returned `200 {"status":"ok"}` on a successful `SELECT 1`, and that was
  the entire check. It answered `200 ok` throughout the deployment failure where
  `PHX_HOST` was unset and *every* LiveView socket was rejected — the pages rendered
  their static HTML and then sat on "Connection lost" forever. A probe that is green
  while 100% of the product is broken is worse than no probe.

  It still cannot see socket rejection (that is a client-side symptom), but it now
  reports the resolved endpoint URL, which is the value that causes it — so one
  `curl` shows a deployer whether `PHX_HOST` is what they think it is.

  It also reports `version`, the commit the running image was built from (see
  `EftBuddy.BuildInfo`). That answers the other question every deploy raises —
  "is this instance actually running the code I just pushed?" — which previously
  took four commands and a comparison of timestamps by eye.

  Both probes sit outside the `:browser` pipeline: no session, no CSRF, no layout.
  Both are exempt from the HTTPS redirect in `config/prod.exs` so a plain-HTTP probe
  reaches the router instead of collecting a 301.
  """
  use EftBuddyWeb, :controller

  alias EftBuddy.BuildInfo
  alias EftBuddy.Cache
  alias EftBuddy.Sync.Freshness
  alias EftBuddy.Sync.Reporter

  # A liveness probe must fail FAST. Without a timeout, a saturated connection pool
  # makes the probe hang for the pool's own queue timeout, so the orchestrator's
  # request times out instead of getting an answer — and a timeout is usually
  # treated as "unknown", not "unhealthy". Answering 503 in 2s is strictly more
  # useful than answering nothing in 15.
  @db_timeout_ms 2_000

  @doc "Liveness: database reachability only."
  def index(conn, _params) do
    db_up? = database_up?()

    body = %{
      status: if(db_up?, do: "ok", else: "degraded"),
      database: if(db_up?, do: "up", else: "down"),
      # The resolved public URL, so a misconfigured PHX_HOST is visible in one curl
      # rather than only as "Connection lost" in every visitor's browser.
      url: EftBuddyWeb.Endpoint.url(),
      # The commit this image was built from. Deliberately on LIVENESS rather
      # than readiness: "what is running here?" must stay answerable even while
      # the instance is degraded, which is exactly when it gets asked.
      version: BuildInfo.sha(),
      uptime_seconds: Freshness.uptime_seconds()
    }

    json_reply(conn, if(db_up?, do: 200, else: 503), body)
  end

  @doc "Readiness: whether the background feeds are fresh enough to serve."
  def sync(conn, _params) do
    freshness = Freshness.evaluate()

    body = %{
      status: to_string(freshness.status),
      uptime_seconds: freshness.uptime_seconds,
      syncs: render_syncs(freshness.syncs),
      # Kept from the original payload: the raw last-run record per label. The
      # verdict above is derived from it, and having both means a reader can see
      # WHY the verdict is what it is without a second request.
      runs: render_runs(),
      # REPORTED, NOT JUDGED. Deliberately excluded from `status`: a cold or
      # even disabled cache is a performance state, not a correctness one, and
      # draining the only instance over a low hit rate would turn a slow site
      # into no site. It is here because the tunnel-only dashboard is not always
      # open and this is the one place the numbers can be read with a curl.
      cache: render_cache()
    }

    json_reply(conn, if(freshness.status == :ok, do: 200, else: 503), body)
  end

  defp json_reply(conn, code, body) do
    conn
    |> put_resp_content_type("application/json")
    # A cached health response is worse than none: it can report a dead instance as
    # live for as long as the cache lasts.
    |> put_resp_header("cache-control", "no-store, max-age=0")
    |> send_resp(code, Jason.encode!(body))
  end

  defp render_syncs(syncs) do
    Map.new(syncs, fn {family, f} ->
      {family,
       %{
         state: to_string(f.state),
         age_seconds: f.age_seconds,
         budget_seconds: f.budget_seconds,
         # A non-zero count means the cleanup guard refused a destructive prune —
         # this instance is knowingly serving a snapshot it distrusted.
         refused_prunes: f.refusals,
         labels: f.labels
       }}
    end)
  end

  defp render_cache do
    stats = Cache.stats()

    %{
      enabled: stats.enabled,
      entries: stats.entries,
      memory_bytes: stats.memory_bytes,
      hits: stats.hits,
      misses: stats.misses,
      # null rather than 0 before anything has been read. "Nothing has been
      # asked for yet" and "everything missed" are opposite diagnoses.
      hit_rate: if(stats.hit_rate, do: Float.round(stats.hit_rate, 4))
    }
  end

  defp render_runs do
    Map.new(Reporter.status(), fn {label, s} ->
      {label,
       %{
         outcome: s.outcome,
         at: DateTime.to_iso8601(s.at),
         duration_ms: s.duration_ms
       }}
    end)
  end

  defp database_up? do
    case Ecto.Adapters.SQL.query(EftBuddy.Repo, "SELECT 1", [], timeout: @db_timeout_ms) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    # A pool checkout timeout exits rather than returning an error tuple.
    :exit, _ -> false
  end
end
