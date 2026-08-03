defmodule EftBuddyWeb.AdminEndpoint do
  @moduledoc """
  A SECOND HTTP endpoint, on its own port, serving only LiveDashboard.

  ## Why a separate endpoint rather than a route on the main one

  The protection here is the network binding, not a plug. The main endpoint has
  to be reachable from the LAN — nginx runs on a different host and proxies to
  it — so anything mounted there is reachable by anything that can reach nginx.
  A `remote_ip` check would not fix that: requests arrive through Docker's NAT
  and then through a reverse proxy, so they do not come from `127.0.0.1` even
  when the human did.

  Giving the dashboard its own port lets `docker-compose.yml` publish it as
  `127.0.0.1:4001:4001`. Docker then binds the host side to loopback only, and a
  packet from the LAN or the internet cannot route to it at all. There is no
  request to authenticate because there is no reachable socket.

  Inside the container this still binds `0.0.0.0` — it has to, or Docker could
  not map it — and that is not a hole: a container's network namespace is only
  reachable through its published ports, and this one is published to loopback.

  ## How a human reaches it

  Over an SSH tunnel:

      ssh -N -L 4001:127.0.0.1:4001 rcorreia@<vm>

  The tunnel's far end originates ON the VM, which is what satisfies the
  loopback binding. Opening it requires an authenticated SSH session, so the
  dashboard's access control is the operator's SSH key — an existing, strong
  credential — rather than a second login this app would have to implement,
  store and rotate.

  That is the whole argument for this design over HTTP basic auth on a public
  route, which `EftBuddyWeb.Router` deliberately removed: a public route can be
  brute forced, credential stuffed, or opened by a missing environment variable.
  This one has no internet-facing surface to attack.

  ## Fail-closed

  `EftBuddy.Application` only starts this endpoint when `:admin_dashboard` config
  is present, which `config/runtime.exs` sets only when `ADMIN_DASHBOARD_PORT`
  is. Unset means the endpoint is never started and the port is never bound —
  the same "does not exist" property the compile-time `:dev_routes` guard gives
  the main router, achieved at boot instead.

  LiveDashboard can read ETS, list processes and KILL them. That is exactly why
  it is worth keeping off any reachable interface.
  """
  use Phoenix.Endpoint, otp_app: :eft_buddy

  # Its own cookie key and salt: this endpoint shares `secret_key_base` with the
  # main one, so a distinct salt keeps the two cookies cryptographically
  # separate rather than interchangeable. Nothing here identifies an operator —
  # the session exists only because LiveView's socket wants one.
  @session_options [
    store: :cookie,
    key: "_eft_buddy_admin_key",
    signing_salt: Application.compile_env(:eft_buddy, :admin_session_signing_salt, "kQ2vRx8L"),
    same_site: "Lax",
    http_only: true,
    max_age: 60 * 60 * 8
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :admin_endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 128_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug EftBuddyWeb.AdminRouter
end
