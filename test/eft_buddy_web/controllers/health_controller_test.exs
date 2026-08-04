defmodule EftBuddyWeb.HealthControllerTest do
  @moduledoc """
  Liveness and readiness are separate routes and must fail for separate reasons.

  The regression being guarded: `/health` returned `200 {"status":"ok"}` on a
  successful `SELECT 1` and nothing else, so it stayed green through the deployment
  failure where every LiveView socket was rejected and every page sat on
  "Connection lost". A probe that is green while 100% of the product is broken is
  worse than no probe, because it is believed.

  NOTE: the `"sync"` key moved out of `/health` and into `/health/sync`. That is the
  split — a load balancer watching liveness must not be told to drain the only
  instance because a wiki scrape is a day late.
  """
  # `async: false` and an explicit reset, because `Reporter`'s status table is
  # global, named and public — the one piece of cross-test shared state in the app.
  # Recording a FAILED run here is not a local act: `EftBuddyWeb.LoadState` reads the
  # same table, so it turns unrelated pages' standby panels into fault markers. That
  # is exactly how these tests first broke `HideoutLiveTest`.
  use EftBuddyWeb.ConnCase, async: false

  alias EftBuddy.Sync.Reporter

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /health — liveness" do
    test "is 200 with the database reachable", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert conn.status == 200
      assert %{"status" => "ok", "database" => "up"} = body(conn)
    end

    test "reports the resolved public URL" do
      # The value that caused the invisible outage: `PHX_HOST` feeds `url:`, which is
      # what `check_origin` validates every socket against. Surfacing it means one
      # curl tells a deployer whether it is what they think it is, instead of the
      # symptom appearing only as "Connection lost" in every visitor's browser.
      assert %{"url" => url} = build_conn() |> get(~p"/health") |> body()
      assert url =~ "http"
    end

    test "reports the commit the image was built from" do
      # The other question every deploy raises — "is this instance actually running
      # what I just pushed?" — which used to take four commands and a comparison of
      # three timestamps by eye. There is no image in the test env, so the honest
      # answer here is "dev"; a release built without the build arg says "unknown".
      assert %{"version" => version} = build_conn() |> get(~p"/health") |> body()
      assert version == "dev"
    end

    test "reports uptime" do
      assert %{"uptime_seconds" => uptime} = build_conn() |> get(~p"/health") |> body()
      assert is_integer(uptime) and uptime >= 0
    end

    test "does NOT go red on a failed sync" do
      # This is the point of splitting the probes. Liveness is what a load balancer
      # watches; if a day-late wiki scrape pulled the only instance out of rotation,
      # a cosmetic problem would become an outage.
      Reporter.attach_telemetry()
      Reporter.with_run("HideoutSync", fn -> {:error, :boom} end)

      conn = build_conn() |> get(~p"/health")

      assert conn.status == 200
      assert body(conn)["status"] == "ok"
    end

    test "/healthz is the same probe" do
      assert build_conn() |> get(~p"/healthz") |> body() |> Map.has_key?("database")
    end

    test "is never cached" do
      # A cached health response can report a dead instance as live for as long as
      # the cache lasts.
      conn = build_conn() |> get(~p"/health")

      assert conn |> get_resp_header("cache-control") |> List.first() =~ "no-store"
    end
  end

  describe "GET /health/sync — readiness" do
    test "a fresh boot is green, not degraded" do
      # Deliberate: in the test VM uptime is seconds, so nothing is overdue yet. A
      # probe that reported unhealthy for the first minutes of every deploy would
      # train its reader to ignore it, and an orchestrator would refuse to bring the
      # instance into rotation at all.
      conn = build_conn() |> get(~p"/health/sync")

      assert conn.status == 200
      assert body(conn)["status"] == "ok"
      assert body(conn)["syncs"]["ItemsSync"]["state"] == "booting"
    end

    test "goes red when a sync fails" do
      Reporter.attach_telemetry()
      Reporter.with_run("MapsSync", fn -> {:error, :upstream_gone} end)

      conn = build_conn() |> get(~p"/health/sync")

      assert conn.status == 503
      assert body(conn)["status"] == "degraded"
      assert body(conn)["syncs"]["MapsSync"]["state"] == "failed"
    end

    test "goes red when a sync refused a destructive prune, despite reporting ok" do
      # End-to-end for the app's most destructive failure mode: the cleanup guard
      # catching a truncated upstream snapshot. The run completes and records
      # `outcome: :ok`, so before this the probe stayed green while the instance
      # knowingly served data it had distrusted.
      Reporter.attach_telemetry()

      Reporter.with_run("ItemsSync", fn ->
        assert {:skip, _} = EftBuddy.Sync.Helpers.cleanup_safe?(100, 1)
        :ok
      end)

      conn = build_conn() |> get(~p"/health/sync")

      assert conn.status == 503
      assert body(conn)["syncs"]["ItemsSync"]["state"] == "guard_tripped"
      assert body(conn)["syncs"]["ItemsSync"]["refused_prunes"] == 1
      # And the run itself still reads as ok, which is exactly why the extra state
      # was needed rather than reusing `outcome`.
      assert body(conn)["runs"]["ItemsSync"]["outcome"] == "ok"
    end

    test "carries the per-family budget so a reader can see WHY" do
      assert %{"budget_seconds" => budget} =
               build_conn()
               |> get(~p"/health/sync")
               |> body()
               |> get_in(["syncs", "PricesSync"])

      assert budget > 0
    end

    test "still carries the raw per-label run record" do
      Reporter.attach_telemetry()
      Reporter.with_run("AmmoSync", fn -> :ok end)

      runs = build_conn() |> get(~p"/health/sync") |> body() |> Map.fetch!("runs")

      assert %{"outcome" => "ok", "at" => at, "duration_ms" => ms} = runs["AmmoSync"]
      assert {:ok, _, _} = DateTime.from_iso8601(at)
      assert is_integer(ms)
    end

    test "is never cached" do
      conn = build_conn() |> get(~p"/health/sync")

      assert conn |> get_resp_header("cache-control") |> List.first() =~ "no-store"
    end
  end

  describe "both probes are reachable without a session" do
    test "no cookie, JSON content type" do
      # They sit outside the `:browser` pipeline so a load balancer can hit them
      # cheaply. If one ever drifted into it, every probe would mint an operator
      # token and the crawler-allocates-nothing property would be lost.
      for path <- ["/health", "/healthz", "/health/sync"] do
        conn = build_conn() |> get(path)

        assert conn.resp_cookies == %{}, "#{path} must not set a cookie"
        assert conn |> get_resp_header("content-type") |> List.first() =~ "application/json"
      end
    end
  end
end
