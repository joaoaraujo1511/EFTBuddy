import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# TEST_DB_*, deliberately NOT the DB_* names that `dev.exs` reads.
#
# These used to be `DB_USERNAME` / `DB_PASSWORD` / `DB_HOSTNAME`, shared with dev
# so a local server with its own password needed no file edit. That sharing is
# only safe while DB_* points at a local Postgres. Once dev points at a hosted
# database — and the `.env` that configures dev is exported into the same shell
# that runs `mix test` — the fallbacks below stop applying and the suite silently
# retargets itself at that hosted instance. The `test` alias in mix.exs opens with
# `ecto.create`, so the first thing it would do is try to CREATE a database there,
# then open `System.schedulers_online() * 2` sandbox connections against it.
#
# Nothing in the suite is written to be safe against a database it does not own.
# A separate prefix means an ambient DB_* can never reach the test repo; point
# these at a local Postgres if its credentials aren't the stock ones. CI sets none
# of them and runs entirely on the fallbacks (.github/workflows/ci.yml).
config :eft_buddy, EftBuddy.Repo,
  username: System.get_env("TEST_DB_USERNAME") || "postgres",
  password: System.get_env("TEST_DB_PASSWORD") || "postgres",
  hostname: System.get_env("TEST_DB_HOSTNAME") || "localhost",
  port: String.to_integer(System.get_env("TEST_DB_PORT") || "5432"),
  database: "eft_buddy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :eft_buddy, EftBuddyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "5k1cZiosMJz+aTTdmtI1B2nTvvyYMPi7dkphmAhFzoasByV6LH0HyhfZpILbbyqA",
  server: false

# Don't start the background sync (periodic Items.Sync + cold-start
# Bootstrap) in tests — they'd hit the live API and race the SQL sandbox.
config :eft_buddy, start_sync: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
