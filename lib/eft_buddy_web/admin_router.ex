defmodule EftBuddyWeb.AdminRouter do
  @moduledoc """
  Routes for `EftBuddyWeb.AdminEndpoint`. LiveDashboard and nothing else.

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
  import Phoenix.LiveDashboard.Router

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

  scope "/" do
    pipe_through :admin

    # `metrics:` wires the summaries and counters declared in
    # `EftBuddyWeb.Telemetry` into the Metrics page — including this app's own
    # `eft_buddy.sync.*`, `operator_sessions.*` and `progress.*` series, which
    # are the ones worth watching. Metrics are IN-MEMORY and reset when the node
    # restarts; this is a live view of a running node, not a time-series store.
    live_dashboard "/dashboard",
      metrics: EftBuddyWeb.Telemetry,
      ecto_repos: [EftBuddy.Repo],
      # The read cache is the one subsystem here that can be wrong without
      # failing: it returns an answer either way, and a stale or badly-keyed one
      # is indistinguishable from a correct one at every other observation
      # point. See `EftBuddyWeb.CacheDashboardPage`.
      additional_pages: [cache: EftBuddyWeb.CacheDashboardPage]

    # Anything else on this endpoint redirects to the dashboard, so a bare
    # `http://localhost:4001` lands somewhere useful over the tunnel.
    get "/", EftBuddyWeb.RedirectController, to: "/dashboard"
  end
end
