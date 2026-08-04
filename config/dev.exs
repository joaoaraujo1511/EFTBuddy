import Config

# TLS to the dev database, VERIFIED — same reasoning as config/runtime.exs, and
# for the same database. This used to be a flat `[verify: :verify_none]`, which
# negotiates TLS and then checks nothing: no confirmation that the peer holding
# the certificate is the host that was asked for. Dev credentials are real
# credentials and this connection leaves the machine, so "it's only dev" does not
# make an unauthenticated peer acceptable.
#
# The pinned CA is not hardening, it is what makes verification possible at all:
# Supabase runs its own PKI, and its root is in no OS trust store, so
# `:public_key.cacerts_get/0` cannot build a path to it. The pinned file is
# committed at priv/certs/ and documented in .env.example, which also carries the
# fingerprint to check it against.
db_hostname = System.get_env("DB_HOSTNAME")

# A LOCAL Postgres is the exception, and it has to be, or this file makes local
# development impossible. A stock local server does not serve TLS at all: Postgrex
# would send the SSLRequest, get `N` back, and fail the connection outright — it
# does not silently downgrade. There is also nothing for verification to protect
# here, since the connection never leaves the machine.
#
# `DB_SSL=true` forces TLS back on for the unusual local server that does serve
# it. Set it and this branch steps aside.
local_db? =
  is_binary(db_hostname) and String.trim(db_hostname) in ~w(localhost 127.0.0.1 ::1)

# NOTHING IN THIS EXPRESSION MAY RAISE. Mix evaluates this file for every task in
# the dev environment, including ones that never open a connection — `format`,
# `deps.get`, `hex.audit`. That is the same trap the `port:` line below documents.
dev_db_ssl =
  cond do
    # Same debug-only escape hatch as prod, and deliberately the same variable
    # name, so what turns verification off is one concept and not two.
    System.get_env("DB_SSL_INSECURE") in ~w(true 1) ->
      [verify: :verify_none]

    local_db? and System.get_env("DB_SSL") not in ~w(true 1) ->
      false

    is_binary(db_hostname) and String.trim(db_hostname) != "" ->
      [
        verify: :verify_peer,
        cacertfile:
          System.get_env("DB_CACERTFILE") ||
            Path.expand("../priv/certs/supabase-prod-ca-2021.crt", __DIR__),
        server_name_indication: String.to_charlist(String.trim(db_hostname)),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]

    true ->
      # No DB_HOSTNAME, so there is no host to connect to and none to verify
      # against. The connection fails later with an error that names the
      # database, exactly as the `port:` note below describes; this branch only
      # has to avoid raising here.
      false
  end

# Configure your database
config :eft_buddy, EftBuddy.Repo,
  username: System.get_env("DB_USERNAME"),
  password: System.get_env("DB_PASSWORD"),
  hostname: System.get_env("DB_HOSTNAME"),
  database: System.get_env("DB_NAME"),
  # DEFAULTED, not required. Mix evaluates this file for EVERY task in the dev
  # environment, including ones that never open a connection — `hex.audit`,
  # `deps.get`, `deps.update`, `format`. A bare `String.to_integer(nil)` here
  # raised ArgumentError from :erlang.binary_to_integer and took all of them
  # down with it, with a stacktrace pointing at erl_eval rather than at the
  # missing variable.
  #
  # The other keys above are left undefaulted on purpose: they resolve to nil
  # and fail later, at connection time, with an error that names the database.
  # Only this line could fail at CONFIG time, which is why only this line needs
  # a fallback. `config/test.exs` defaults its equivalent the same way.
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  stacktrace: true,
  # LOCAL ONLY. This flag makes Ecto include the full connection options — the
  # PASSWORD among them — in the crash report when the Repo fails to start. That
  # is a fair trade for a local server whose credentials are `postgres/postgres`,
  # and a bad one the moment DB_HOSTNAME points somewhere real: a single typo in
  # the password then prints the correct one to the terminal and into whatever
  # scrollback, screen share or log file is watching.
  #
  # This project has already had that happen once. Pointing dev at the hosted
  # database to reproduce a latency problem is a legitimate thing to do, and it
  # should not be the thing that leaks the credential.
  show_sensitive_data_on_connection_error: local_db?,
  pool_size: 10,
  # Supabase requires TLS. Options live inside `ssl:` — the separate `ssl_opts`
  # key is deprecated in Postgrex and is ignored with a warning. Built above,
  # where the reasoning lives.
  ssl: dev_db_ssl

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :eft_buddy, EftBuddyWeb.Endpoint,
  # LOOPBACK BY DEFAULT. This used to be `{0, 0, 0, 0}` unconditionally, with a
  # `#! Change back to default before deployment !#` comment that nothing enforced.
  # Combined with `check_origin: false` and the committed `secret_key_base` below,
  # that made the dev server reachable from anywhere on the local network by anyone
  # who can read this repository — and the whole point of publishing it is that
  # everyone can.
  #
  # Set `DEV_BIND_ALL=1` when you actually want that (testing the HUD on a phone).
  # Read at compile time, which for a dev convenience is fine: `mix phx.server`
  # compiles on start, so exporting the variable and restarting is enough.
  http: [
    ip:
      if(System.get_env("DEV_BIND_ALL") in ~w(1 true),
        do: {0, 0, 0, 0},
        else: {127, 0, 0, 1}
      )
  ],
  # Phoenix's dev default. Safe now that the default bind is loopback; if you set
  # DEV_BIND_ALL you are also turning this off for the LAN, which is the reason the
  # bind is opt-in.
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  # Dev-only key, and deliberately committed — this is upstream Phoenix's own
  # generator behaviour. Production reads `secret_key_base` from the environment in
  # config/runtime.exs, which hard-raises when it is missing or blank, so this value
  # can never reach a deployed instance.
  #
  # NOT ROTATED, deliberately. Rotating a value that is committed either way
  # achieves nothing: the replacement would be equally public the moment anyone
  # clones the repository. What actually mattered was that this key was paired with
  # a server bound to every interface, and that is what changed above. The rule to
  # keep is the invariant, not the number: nothing in dev or test config may ever be
  # a value production could fall back to.
  secret_key_base: "MCvjv+WvfXN4eYNlaPdaJR2pDUyya4fofpU2kTYN+Xhq1S8r5JSWFouYjuOBwqjL",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:eft_buddy, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:eft_buddy, ~w(--watch)]}
  ]

# ## SSL Support
#
# In order to use HTTPS in development, a self-signed
# certificate can be generated by running the following
# Mix task:
#
#     mix phx.gen.cert
#
# Run `mix help phx.gen.cert` for more information.
#
# The `http:` config above can be replaced with:
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       keyfile: "priv/cert/selfsigned_key.pem",
#       certfile: "priv/cert/selfsigned.pem"
#     ],
#
# If desired, both `http:` and `https:` keys can be
# configured to run both http and https servers on
# different ports.

# Reload browser tabs when matching files change.
config :eft_buddy, EftBuddyWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      # Gettext translations
      ~r"priv/gettext/.*\.po$",
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/eft_buddy_web/router\.ex$",
      ~r"lib/eft_buddy_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

# Enable dev routes for the dashboard
config :eft_buddy, dev_routes: true

# The session cookie is `Secure` everywhere except dev. `http:` above binds
# 0.0.0.0, and reaching the dev server on a LAN address over plain http:// is not
# a secure context, so the browser would drop a `Secure` cookie and the operator
# HUD would silently render defaults. (http://localhost is exempt from that rule;
# a LAN IP is not.) See `EftBuddyWeb.Endpoint`'s `@session_options`.
config :eft_buddy, :session_cookie_secure, false

# Do not include metadata nor timestamps in development logs
# Timestamp is wrapped in green ANSI escapes so it visually
# anchors each line. Set here (dev only) rather than in the
# base config so the production formatter stays unchanged —
# log shippers / journald / CloudWatch don't see escape codes.
config :logger, :default_formatter, format: "\e[32m[$date $time] >\e[0m [$level] $message\n"

# Enable ANSI escapes in dev so EftBuddy.Sync.Reporter.colorize_label/1
# (and anyone else gating on `IO.ANSI.enabled?/0`) actually emits colors.
# Intentionally not set in prod: log shippers / journald / CloudWatch
# render escape codes as `\e[36m…` garbage when ANSI isn't filtered.
config :elixir, :ansi_enabled, true

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Read cache OFF in development. In production it is what keeps every page from
# paying ~76ms per query to a database in another region; locally the database is
# on this machine, so it buys nothing and actively gets in the way — a syncer run
# or a manual `Repo.insert` would not show up until the entry expired.
#
# Set `CACHE_ENABLED=1` to exercise it locally.
config :eft_buddy, cache_enabled: System.get_env("CACHE_ENABLED") in ~w(1 true)

# The background sync, on by default in dev (a fresh local database populates
# itself), but switchable OFF.
#
# The case that needs it: pointing dev at the HOSTED database to reproduce
# something that only happens at 75ms of latency. Reads against it are harmless,
# but the syncers write — so a dev instance left on its defaults would start
# writing to production from a laptop, and `:global` locks do not span
# un-clustered nodes, so it would not even notice the real instance doing the
# same thing.
#
# `START_SYNC=0` makes the connection read-only in practice. Cache invalidation
# and warming both hang off the `[:eft_buddy, :sync, :stop]` telemetry event
# rather than off the syncers themselves, so they can still be exercised by
# emitting that event by hand — see EftBuddy.Sync.Reporter.
config :eft_buddy, start_sync: System.get_env("START_SYNC", "1") not in ~w(0 false no)

# The in-memory item catalogue, off for the same reason. `ITEM_DATASET=1`
# exercises it against the local database — worth doing before a deploy, since
# it is the one layer that reimplements query semantics rather than skipping a
# query, and the Items/Flea pages should look identical with it on and off.
#
# Note when comparing: a stock local Postgres and Supabase do NOT use the same
# collation, so the two environments legitimately order punctuation-leading item
# names differently. The dataset follows whichever database it is talking to.
config :eft_buddy, item_dataset_enabled: System.get_env("ITEM_DATASET") in ~w(1 true)
