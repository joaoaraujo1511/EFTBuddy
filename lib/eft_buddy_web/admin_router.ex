defmodule EftBuddyWeb.AdminRouter do
  @moduledoc """
  Routes for `EftBuddyWeb.AdminEndpoint`: the full readiness payload, and
  nothing else.

  It used to serve LiveDashboard. That was never finished or used, and a fuller
  operator dashboard is planned, so the route is gone while the dashboard pages
  (`EftBuddyWeb.CacheDashboardPage`, `EftBuddyWeb.SyncDashboardPage`) stay in the
  tree for it to reuse. What remains is the detailed `/health/sync`, trimmed from
  the public one because the public one is reachable by anyone.

  Deliberately separate from `EftBuddyWeb.Router`: that router serves the public
  site and must never gain an operator surface, which is a property worth keeping
  visible in the file layout rather than only in a comment.
  """
  # Same import set as `EftBuddyWeb.router/0`, spelled out rather than reused via
  # `use EftBuddyWeb, :router`: that macro is the public site's router contract,
  # and this endpoint should not silently inherit changes made for the public
  # site's benefit.
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery

    # NO Content-Security-Policy here, unlike the public router's strict one.
    # LiveDashboard bootstraps itself with an inline <script>, so a `script-src
    # 'self'` policy blanks the page. The public site's CSP is real defence
    # against XSS in operator-authored and third-party content; this endpoint
    # renders only LiveDashboard's own markup, to a socket that is not reachable
    # off the host. `put_secure_browser_headers` still sets the frame, sniffing
    # and referrer protections.
    #
    # The app used to carry a `DashboardCsp` plug that swapped in a nonce policy
    # for exactly this reason. It is not resurrected here because it existed to
    # make a PUBLIC dashboard route safe, and this route is not public.
    plug :put_secure_browser_headers
  end

  # The detailed readiness payload. JSON, no session: the same shape of route as
  # the public probes, on an endpoint that is not reachable off the host.
  pipeline :probe do
    plug :accepts, ["json"]
  end

  scope "/", EftBuddyWeb do
    pipe_through :probe

    get "/health/sync", HealthController, :sync_detail
  end

  # LiveDashboard, disabled: never finished or used, and to be replaced by a
  # fuller dashboard. Restoring it is these lines, plus
  # `import Phoenix.LiveDashboard.Router` above:
  #
  #     scope "/" do
  #       pipe_through :admin
  #       live_dashboard "/dashboard", metrics: EftBuddyWeb.Telemetry,
  #         ecto_repos: [EftBuddy.Repo],
  #         additional_pages: [cache: EftBuddyWeb.CacheDashboardPage,
  #                            syncs: EftBuddyWeb.SyncDashboardPage]
  #     end
end
