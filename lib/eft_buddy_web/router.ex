defmodule EftBuddyWeb.Router do
  use EftBuddyWeb, :router

  # Content-Security-Policy for the public site. Defense-in-depth against
  # XSS on top of HEEx auto-escaping. Notes:
  #   * `script-src 'self'` - all JS is bundled (app.js); no inline
  #     scripts or inline event handlers (the old `onerror=` on the
  #     trader rank emblem was removed for exactly this reason).
  #   * `style-src 'self' 'unsafe-inline'` - a few genuinely *dynamic*
  #     values are set via inline `style` attributes that can't be
  #     pre-enumerated as classes: the scav-karma slider fill %, the
  #     chapter-glyph mask URL, per-value ammo stat colours, hideout
  #     progress-bar widths and event-change indents. (Enumerable cases
  #     like item tier backgrounds now use `.item-bg-*` utility classes,
  #     so the allowance is only kept for the dynamic remainder.) Fonts
  #     are self-hosted so no external style/font origin is needed.
  #   * `img-src 'self' data: https:` - item / wiki imagery is hot-linked
  #     from several CDNs (tarkov.dev, the Fandom wiki); restrict to https
  #     rather than enumerating every CDN host.
  #   * `frame-ancestors 'none'` / `object-src 'none'` / `base-uri 'self'`
  #     - clickjacking + injection hardening.
  @csp Enum.join(
         [
           "default-src 'self'",
           "base-uri 'self'",
           "frame-ancestors 'none'",
           "object-src 'none'",
           "img-src 'self' data: https:",
           "font-src 'self'",
           "style-src 'self' 'unsafe-inline'",
           "script-src 'self'",
           "connect-src 'self'",
           # Forms submit only to this site (L29). Every form here is a LiveView
           # form or `POST /session/reset`; nothing posts elsewhere.
           "form-action 'self'"
         ],
         "; "
       )

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # Mints the per-browser `operator_token` and bridges the `eft_prefs` cookie
    # into the session, so a LiveView mount can resolve (or cold-seed) the
    # operator's server-side session. See the plug's moduledoc.
    plug EftBuddyWeb.Plugs.OperatorSession
    plug :fetch_live_flash
    plug :put_root_layout, html: {EftBuddyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # NO ADMIN / DASHBOARD-AUTH PIPELINE, deliberately.
  #
  # There were two: a hand-written `EftBuddyWeb.Plugs.DashboardAuth` (fail-closed
  # HTTP basic auth over two environment variables) and a `DashboardCsp` that
  # swapped in a nonce policy so LiveDashboard's inline bootstrap script could
  # run. Both were removed, along with the `/dev/reports` triage page they gated.
  #
  # The reasoning is not that they were broken — the credential comparison was
  # `Plug.BasicAuth`/`Plug.Crypto.secure_compare` library code, and the gate
  # failed closed to 404. It is that an authenticated admin surface exposed to
  # the internet is a category of risk this app does not need to carry at launch.
  # LiveDashboard is now mounted the way `mix phx.new` generates it — behind the
  # `:dev_routes` compile flag, so the route does not exist in a production
  # build at all. A route that is not compiled cannot be misconfigured, brute
  # forced, or left open by a missing environment variable.
  #
  # The cost is real and is recorded in `EftBuddyWeb.Telemetry`: no metric is
  # observable in production. `/health` and `/health/sync` are the whole
  # production observability story now. If an operator surface is ever wanted
  # back, prefer the database host's own console (real accounts, 2FA, an audit
  # trail) over re-adding a route here.

  # Probes. Deliberately outside the `:browser` pipeline (no session, no CSRF, no
  # layout) so they're cheap, headerless JSON a load balancer can hit.
  #
  # LIVENESS and READINESS are separate routes on purpose. `/health` answers "can
  # this process serve at all?" (database only) and is what a load balancer should
  # watch — it must never go red on stale data, or a day-late wiki scrape would pull
  # the only instance out of rotation and turn a cosmetic problem into an outage.
  # `/health/sync` answers "is the data fresh?" and DOES go red, because this app has
  # no user-authored content: a sync that stops or truncates produces no error, the
  # pages keep rendering, and stale or missing game data is presented as fact.
  #
  # Both are exempt from the HTTPS redirect in config/prod.exs (`force_ssl`'s
  # `:exclude`), so a plain-HTTP probe reaches the router instead of a 301.
  scope "/", EftBuddyWeb do
    pipe_through :api

    get "/health", HealthController, :index
    get "/healthz", HealthController, :index
    get "/health/sync", HealthController, :sync
  end

  scope "/", EftBuddyWeb do
    pipe_through :browser

    # The Tasks page is the app's landing page; the bare root redirects to
    # it so `/tasks` stays the single canonical URL.
    get("/", RedirectController, to: "/tasks")

    # Hard reset of the operator's server-side state, used by the "Reset
    # progress" / "Import backup" actions. Deliberately a normal form POST
    # rather than a LiveView event - see the controller's moduledoc.
    #
    # POST, not GET, and that matters for more than REST tidiness. This route
    # discards progress and rotates the operator token, and the reset broadcasts
    # to the operator's other open tabs, emptying their `:client_state`; their
    # next write then pushes that empty blob over `localStorage`, which is the
    # only durable copy of the operator's progress. As a GET it was reachable by
    # a cross-site top-level navigation - `same_site: "Lax"` still sends the
    # session cookie on those - so a posted link could destroy a visitor's whole
    # tracker. `:protect_from_forgery` above only validates non-idempotent
    # methods, so making this a POST is what actually brings it under CSRF
    # protection. It must never go back to being a GET.
    post("/session/reset", SessionController, :reset)

    # Static prose. A plain controller rather than a live route: there is
    # nothing to update, and putting it in `live_session :operator` would open a
    # socket and mint an `EftBuddy.OperatorSession` to render a page of text.
    get("/privacy", PageController, :privacy)

    # Every page lives in ONE named live_session, declared explicitly rather
    # than relying on Phoenix's implicit `:default`. Two things depend on it:
    #
    #   * `<.link navigate>` only does client-side live navigation *within* a
    #     live_session. Keeping every route here is what makes navigation a
    #     LiveView remount over the existing socket rather than a page reload.
    #   * The `on_mount` hooks below therefore run on every navigation, which
    #     is where the operator's HUD state and progress are resolved.
    #
    # The hooks are declared here (not in `EftBuddyWeb.live_view/0`) so the
    # mount pipeline is visible at the routing layer and runs exactly once.
    # Order matters: `OperatorState` establishes `:operator_token` and the
    # operator assigns, then `ClientBridge` attaches the transport events that
    # depend on that token.
    live_session :operator,
      on_mount: [EftBuddyWeb.OperatorState, EftBuddyWeb.ClientBridge] do
      live("/items", ItemsLive.Index, :index)
      live("/ammo", AmmoLive.Index, :index)
      live("/tasks", TasksLive.Index, :index)
      live("/events", EventsLive.Index, :index)
      live("/maps", MapsLive.Index, :index)
      live("/maps/:slug", MapsLive.Show, :show)
      live("/flea-market", FleaMarketLive.Index, :index)
      live("/storyline", StorylineLive.Index, :index)
      live("/storyline/:slug", StorylineLive.Show, :show)
      live("/hideout", HideoutLive.Index, :index)
      live("/report-bug", ReportBugLive.Index, :index)
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", EftBuddyWeb do
  #   pipe_through :api
  # end

  if Application.compile_env(:eft_buddy, :dev_routes) do
    # LiveDashboard is not mounted here any more. It was never finished or used,
    # a fuller operator dashboard is planned, and under this router's CSP
    # (`script-src 'self'`) its inline bootstrap script was blocked, so the page
    # never connected anyway. The dashboard pages stay in the tree; see
    # `EftBuddyWeb.AdminRouter` for how to restore it.

    # Preview the themed error pages locally (dev only). `debug_errors: true`
    # otherwise hides them behind Phoenix's debug page. e.g. /dev/errors/404.
    scope "/dev", EftBuddyWeb do
      pipe_through :browser

      get "/errors/:code", ErrorPreviewController, :show
    end
  end
end
