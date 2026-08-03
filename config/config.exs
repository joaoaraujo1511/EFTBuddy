# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :eft_buddy,
  ecto_repos: [EftBuddy.Repo],
  generators: [timestamp_type: :utc_datetime],
  # Start the background data sync (the periodic Items.Sync GenServer and
  # the cold-start Bootstrap task) on boot. Disabled in test so the suite
  # never hits the live Tarkov.dev API or races the Ecto SQL sandbox.
  start_sync: true,
  # Tasks whose objective payloads from tarkov.dev are misleading (they
  # list every key / build-material / barter currency the task *can*
  # accept rather than what the user must actually grind). Filtered out
  # of the per-item "needed by quests" list and the "Quest items" scope.
  # Matched by exact task name; override per environment if the API data
  # changes. Read via `Application.compile_env/3` in `EftBuddy.Items`.
  task_objective_blacklist: ["Key Partner", "Building Foundations", "Circulate"],
  # Base URL of the tarkov.dev JSON API (https://json.tarkov.dev). Every
  # bit of game data (items, prices, tasks, maps, hideout, traders,
  # barters, crafts) is synced from here via `EftBuddy.TarkovApi`. Kept
  # in config (rather than hard-coded per sync module like the old
  # GraphQL URL was) so a local mirror can be pointed at for tests /
  # offline development. No trailing slash.
  tarkov_json_api_url: "https://json.tarkov.dev"

# Silence Ecto's built-in per-query logger. `EftBuddy.Sync.Reporter`
# attaches its own telemetry handler that:
#   - Outside a sync run: emits an Ecto-style debug log (so dev
#     request-time queries still show up like before).
#   - Inside a sync run (`Reporter.with_run/2`): just increments
#     per-op counters that get rolled up into a single summary
#     line per sync module instead of thousands of per-query lines.
config :eft_buddy, EftBuddy.Repo, log: false

# Configure the endpoint
config :eft_buddy, EftBuddyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EftBuddyWeb.ErrorHTML, json: EftBuddyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EftBuddy.PubSub,
  # Like the session salt in `EftBuddyWeb.Endpoint`, this is a domain separator
  # rather than a secret: the signing key is derived from it AND
  # `secret_key_base`, which is env-supplied in prod. Unlike the session salt this
  # one lives in endpoint config, so `config/runtime.exs` can override it from the
  # environment for rotation without a rebuild.
  live_view: [signing_salt: "YFkgry97"]

# The operator dashboard's endpoint (see `EftBuddyWeb.AdminEndpoint`). This block
# only makes the module compilable — `server: false` means nothing here starts
# it. `EftBuddy.Application` starts it ONLY when `:admin_dashboard` is set, which
# `config/runtime.exs` does only when ADMIN_DASHBOARD_PORT is present. Unset in
# every environment by default, so the port is never bound and the socket never
# exists.
config :eft_buddy, EftBuddyWeb.AdminEndpoint,
  server: false,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: EftBuddyWeb.ErrorHTML], layout: false],
  pubsub_server: EftBuddy.PubSub,
  live_view: [signing_salt: "aH7dK2mQ"],
  # Reached only through an SSH tunnel, so the browser's Origin is always the
  # loopback address the tunnel listens on — never the app's public host. An
  # explicit list rather than `false`: this endpoint can kill processes, so a
  # websocket from a page on another origin should still be refused.
  check_origin: [
    "//localhost",
    "//127.0.0.1",
    "http://localhost:4001",
    "http://127.0.0.1:4001"
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  eft_buddy: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  eft_buddy: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
