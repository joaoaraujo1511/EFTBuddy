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

  # TLS to the database, VERIFIED. `ssl: true` is not the same thing and is what
  # this used to pass: it hands Postgrex a bare boolean, and what that negotiates
  # depends on the Postgrex version rather than on anything stated here. An
  # unverified TLS session to a database reachable over the public internet — which
  # a hosted provider's pooler is — is protection against passive sniffing only. It
  # stops nothing active, because there is no check that the peer presenting the
  # certificate is the host we asked for.
  #
  # So verification is explicit and on by default:
  #
  #   verify: :verify_peer  — actually check the chain, rather than accept any cert.
  #   cacerts               — the OS trust store. The runtime image MUST ship
  #                           `ca-certificates` or `cacerts_get/0` raises at boot.
  #                           That is deliberate: failing to start beats starting
  #                           with an unverified connection to the database.
  #   server_name_indication — SNI, taken from DATABASE_URL's host. Managed
  #                           providers front many databases behind one address and
  #                           serve the wrong certificate without it.
  #   customize_hostname_check — Erlang's default hostname matching is stricter than
  #                           the HTTPS rules most public CAs issue against
  #                           (wildcards, in particular); the `:https` match fun is
  #                           the standard remedy and is not a weakening.
  #
  # DB_SSL_INSECURE=true drops to `verify_none`. It exists so a certificate problem
  # can be isolated from a connectivity problem in one restart, NOT as a setting to
  # leave on. It is a separate variable from DB_SSL precisely so that turning TLS on
  # can never quietly mean turning verification off.
  #
  # DB_CACERTFILE replaces the OS trust store with one pinned CA, and it is what
  # makes `verify_peer` reachable at all against a provider running its own PKI.
  # Supabase does: its pooler serves a chain rooted at `Supabase Root 2021 CA`,
  # which is Supabase's own root and is in no OS trust store, so `cacerts_get/0`
  # cannot build a path to it and verification fails however correct the rest of
  # this list is. That failure is precisely what DB_SSL_INSECURE was papering
  # over, and swapping one variable for the other is the actual fix rather than a
  # softer workaround. Get the file from the Supabase dashboard, under
  # Database -> Settings -> SSL Configuration.
  #
  # Pinning is TIGHTER than the default, not a concession: it trusts exactly one
  # issuer for this connection instead of every public CA on the machine.
  db_ssl =
    if System.get_env("DB_SSL") in ~w(true 1) do
      db_host =
        case URI.parse(database_url) do
          %URI{host: host} when is_binary(host) and host != "" ->
            host

          _ ->
            raise """
            DB_SSL is enabled but no hostname could be parsed out of DATABASE_URL,
            so the certificate could not be checked against anything.

            Expected a URL of the form ecto://USER@HOST/DATABASE.
            """
        end

      if System.get_env("DB_SSL_INSECURE") in ~w(true 1) do
        [verify: :verify_none]
      else
        # Either one pinned root, or the OS store. Never both: adding the public
        # CAs back alongside a pinned root would mean any of them could also vouch
        # for this host, which is the property pinning exists to remove.
        trust_anchor =
          case System.get_env("DB_CACERTFILE") do
            path when is_binary(path) and path != "" ->
              path = String.trim(path)

              # Both checks run at boot on purpose. A wrong path or a file that is
              # not a certificate should name itself here, in a message that says
              # which file, rather than surface later as an opaque handshake
              # failure inside Postgrex. The second check is not hypothetical: a
              # CA fetched from a stale URL comes back as a 404 HTML page, which
              # saves under a `.crt` name perfectly happily.
              pem =
                case File.read(path) do
                  {:ok, pem} ->
                    pem

                  {:error, reason} ->
                    raise """
                    DB_CACERTFILE is set to #{path}, which could not be read: \
                    #{:file.format_error(reason)}.

                    This is the CA that verifies the database's certificate. Check the
                    path exists and is readable by the user the app runs as — in a
                    container, that it is actually mounted in.
                    """
                end

              if Enum.any?(:public_key.pem_decode(pem), &match?({:Certificate, _, _}, &1)) do
                [cacertfile: String.to_charlist(path)]
              else
                raise """
                DB_CACERTFILE is set to #{path}, but that file contains no PEM
                certificate.

                Expected a `-----BEGIN CERTIFICATE-----` block. A download that
                silently returned an error page is the usual cause; re-download the
                CA from the provider's dashboard.
                """
              end

            _ ->
              [cacerts: :public_key.cacerts_get()]
          end

        [
          verify: :verify_peer,
          server_name_indication: String.to_charlist(db_host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ trust_anchor
      end
    else
      false
    end

  config :eft_buddy, EftBuddy.Repo,
    url: database_url,
    # The password is supplied separately (and applied as an explicit
    # override on top of whatever DATABASE_URL parses to) so it never has
    # to live inside the URL — keeping it out of logs, crash dumps, and
    # anywhere the URL might be echoed. To carry it in DATABASE_URL
    # instead, drop the DB_PASSWORD requirement above and this line.
    password: db_password,
    # `false`, or a verified TLS option list. Built above, where the reasoning
    # lives. Note this is the `ssl:` key and NOT the deprecated `ssl_opts:` —
    # see the same note in config/dev.exs.
    ssl: db_ssl,
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

  # The read cache, ON unless explicitly disabled. This is a KILL SWITCH, not a
  # feature flag: the cache is the difference between a page rendering in 3 ms
  # and 1,500 ms, so it should never need turning off — but if it ever serves
  # something wrong, `CACHE_ENABLED=0` in .env plus a restart is seconds, while
  # reverting the code is an Elixir release build and minutes of an evening.
  #
  # `EftBuddy.Cache.enabled?/0` already defaults to true, so this only ever
  # subtracts. Warming reads the same flag and does nothing while it is off.
  config :eft_buddy,
         :cache_enabled,
         System.get_env("CACHE_ENABLED", "1") not in ~w(0 false no)

  # The in-memory item catalogue, OFF unless ITEM_DATASET is set.
  #
  # Opt-IN rather than opt-out, unlike the read cache above, because this one
  # does not merely skip a query — it reimplements filtering, ordering and
  # pagination, so its failure mode is returning the wrong ROWS rather than
  # returning them slowly. Every read through it also falls back to SQL when the
  # layer is not ready, so switching it off is a config change and a restart
  # rather than a rebuild. See `EftBuddy.Items.Dataset`.
  config :eft_buddy,
         :item_dataset_enabled,
         System.get_env("ITEM_DATASET", "0") in ~w(1 true yes)

  # The operator dashboard, OFF unless ADMIN_DASHBOARD_PORT is set. Absent, the
  # `:admin_dashboard` key is never written, `EftBuddy.Application` never adds the
  # endpoint to the supervision tree, and nothing binds the port. Fail-closed by
  # omission rather than by a flag someone can set to the wrong string.
  #
  # It binds 0.0.0.0 INSIDE the container because Docker cannot map a
  # loopback-bound container port. The restriction lives in docker-compose.yml,
  # which publishes it as `127.0.0.1:<port>:<port>` — so the HOST side is
  # loopback-only and nothing off the machine can route to it. Reach it with:
  #
  #     ssh -N -L 4001:127.0.0.1:4001 user@host
  #
  # See `EftBuddyWeb.AdminEndpoint` for why this is a separate endpoint and why
  # the SSH key is the access control.
  if admin_port = System.get_env("ADMIN_DASHBOARD_PORT") do
    config :eft_buddy, :admin_dashboard, true

    config :eft_buddy, EftBuddyWeb.AdminEndpoint,
      server: true,
      http: [ip: {0, 0, 0, 0}, port: String.to_integer(admin_port)],
      secret_key_base: secret_key_base
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
