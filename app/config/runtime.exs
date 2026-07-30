import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/eft_buddy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :eft_buddy, EftBuddyWeb.Endpoint, server: true
end

config :eft_buddy, EftBuddyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # Every required variable goes through this rather than `||`, because `||` only
  # tests truthiness and `""` is truthy. A blank value is not a hypothetical: it is
  # what an env file line reading `PHX_HOST=` produces, what a host's dashboard
  # produces when the field is saved empty, and what any templating layer produces
  # for a variable it could not resolve. Two of the four happen to fail loudly anyway
  # (an empty DATABASE_URL will not parse; an empty SECRET_KEY_BASE trips Phoenix's
  # key-length check) but PHX_HOST booted perfectly cleanly and broke the entire
  # product - see its own note below.
  require_env = fn name, hint ->
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> raise "environment variable #{name} is set but blank.\n#{hint}"
          trimmed -> trimmed
        end

      nil ->
        raise "environment variable #{name} is missing.\n#{hint}"
    end
  end

  db_password =
    require_env.("DB_PASSWORD", "Load it from .env before starting the app.")

  database_url =
    require_env.(
      "DATABASE_URL",
      "For example: ecto://USER@HOST/DATABASE (the password is supplied via DB_PASSWORD)."
    )

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :eft_buddy, EftBuddy.Repo,
    url: database_url,
    # The password is supplied separately (and applied as an explicit
    # override on top of whatever DATABASE_URL parses to) so it never has
    # to live inside the URL — keeping it out of logs, crash dumps, and
    # anywhere the URL might be echoed. To carry it in DATABASE_URL
    # instead, drop the DB_PASSWORD requirement above and this line.
    password: db_password,
    # Enable TLS to the database by setting DB_SSL=true. Some managed
    # providers also need extra `ssl_opts` (CA bundle / SNI) for full
    # certificate verification — see https://hexdocs.pm/postgrex.
    ssl: System.get_env("DB_SSL") in ~w(true 1),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    require_env.("SECRET_KEY_BASE", "You can generate one by calling: mix phx.gen.secret")

  # Raises rather than defaulting, because the default was silently catastrophic:
  # `host` feeds `url: [host: ...]`, which is what `check_origin` validates every
  # LiveView websocket against. Deployed at a real hostname with `PHX_HOST` unset,
  # EVERY socket connection was rejected - pages rendered their static HTML and then
  # sat on "Connection lost", i.e. 100% of the product broken - while `/health`
  # still returned 200 "ok" because it only checks the database. The same value also
  # drives the `force_ssl` redirect target and every canonical / og:url tag.
  #
  # Presence is not enough, which is why this one gets a SHAPE check too.
  # `check_origin` compares the raw string against `URI.parse(origin).host`
  # (phoenix/socket/transport.ex), so `https://eftbuddy.example`,
  # `eftbuddy.example:443` and `eftbuddy.example/` all fail in exactly the same
  # silent, everything-is-broken-but-healthy way as a blank value. A bare hostname
  # is the only correct form, so anything else must fail at boot.
  host =
    require_env.(
      "PHX_HOST",
      "Set it to the public hostname this instance is served from, e.g. eftbuddy.example."
    )

  if String.contains?(host, ["/", ":", " ", "?", "@"]) do
    raise """
    environment variable PHX_HOST must be a BARE hostname - no scheme, port, path or
    credentials. Got: #{inspect(host)}

    It is compared verbatim against each websocket's Origin header by check_origin,
    so a scheme or port here rejects every LiveView connection while the page still
    renders and /health still answers 200. Set the port with PORT instead.
    """
  end

  config :eft_buddy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Optional rotation of the LiveView signing salt without a rebuild. Not a
  # secret (see the note in config/config.exs), but rotatable is better than
  # fixed, and this one is endpoint config so it CAN be set at runtime — the
  # session salt in `EftBuddyWeb.Endpoint` is a compile-time attribute and cannot.
  if salt = System.get_env("LIVE_VIEW_SIGNING_SALT") do
    config :eft_buddy, EftBuddyWeb.Endpoint, live_view: [signing_salt: salt]
  end

  # Concurrent operator sessions, sized to the instance's memory rather than to a
  # process count. Raise it on a bigger box; the default is deliberately low
  # because overshooting kills the node while undershooting only degrades new
  # visitors to cookie-only state.
  #
  # An OVERRIDE, not a default with its own copy of the number - unlike POOL_SIZE
  # above. `EftBuddy.OperatorSessions.ceiling/0` owns the default and the
  # arithmetic behind it, and two modules read it.
  if max_sessions = System.get_env("MAX_OPERATOR_SESSIONS") do
    config :eft_buddy, :max_operator_sessions, String.to_integer(max_sessions)
  end

  config :eft_buddy, EftBuddyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :eft_buddy, EftBuddyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :eft_buddy, EftBuddyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
