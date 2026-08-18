defmodule EftBuddyWeb.RuntimeConfigTest do
  @moduledoc """
  Executes `config/runtime.exs`'s **production** branch and asserts it refuses to
  boot on bad input.

  This branch never runs in the test environment, so until now the single
  highest-impact configuration guard in the app — the one whose absence broke 100%
  of LiveView sockets while `/health` answered `200 ok` — had no coverage at all.
  `Config.Reader.read!/2` evaluates the file for real, including its `raise`s, which
  is exactly what a release's config provider does at boot.

  `async: false`: these manipulate process-wide environment variables.
  """
  use ExUnit.Case, async: false

  @runtime_config Path.join([__DIR__, "..", "..", "config", "runtime.exs"]) |> Path.expand()

  # Not secrets: throwaway values that only have to satisfy the shape checks.
  @valid %{
    "SECRET_KEY_BASE" => String.duplicate("x", 64),
    "DATABASE_URL" => "ecto://postgres@127.0.0.1/eft_buddy_shape_test",
    "DB_PASSWORD" => "placeholder",
    "PHX_HOST" => "eftbuddy.example"
  }

  # Optional variables the prod branch reads. Tracked here purely so `on_exit`
  # restores them: a test that switches DB_SSL on must not leak it into the next
  # one, which would silently change what that test is asserting about.
  @optional ~w(DB_SSL DB_SSL_INSECURE DB_CACERTFILE)

  setup do
    original = Map.new(Map.keys(@valid) ++ @optional, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp read_prod(overrides) do
    Enum.each(Map.merge(@valid, overrides), fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    Config.Reader.read!(@runtime_config, env: :prod)
  end

  defp repo_ssl(config), do: get_in(config, [:eft_buddy, EftBuddy.Repo, :ssl])

  # A real certificate, not a stub — but a throwaway one, generated for this
  # fixture and used nowhere. Nothing here verifies a connection with it; it only
  # has to be something `:public_key.pem_decode/1` accepts as a certificate.
  #
  # This used to be the hosted provider's public root, on the argument that the
  # genuine article kept the fixture honest. That database is gone, so there is no
  # genuine article left to point at, and pinning to some unrelated third party's
  # root would imply a relationship the code no longer has. A self-signed CA says
  # plainly what this is: shaped like a certificate, meaningful to nothing.
  # Contains no private key, and expires in 2046.
  defp test_root_pem do
    """
    -----BEGIN CERTIFICATE-----
    MIIDIzCCAgugAwIBAgIUbm63n+0uMtE0TFlVK52H1AyIpDIwDQYJKoZIhvcNAQEL
    BQAwITEfMB0GA1UEAwwWRUZUIEJ1ZGR5IFRlc3QgUm9vdCBDQTAeFw0yNjA4MTgx
    OTQ1MDVaFw00NjA4MTMxOTQ1MDVaMCExHzAdBgNVBAMMFkVGVCBCdWRkeSBUZXN0
    IFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDKwZd2aYGO
    pVDIamldlB6tNvLXoQAr3uHg8KslHxWwtdOyKm4KaSZsU2Ctj+jVDmcsM15p8O7j
    4+lRzS2AwUkrZKjw4zPlEqrCytFgkfLpZZbiuxKodwimMlVApMZGRWwAewWnJ+6I
    N/OzNoH3KrvMi6ZEQ46TUWfd5hFtetrDvCffF/6CNR7xAjfJi7FhqO6hiHWM3YOA
    7rBoi/ElnggbImcgMY/Ih0y00S04g0BJGLaHBw4kMWzRL3xBDy5aG9tKUTv2Mh4+
    hTeT6eTTu4QKf4gRaIF4LyUnlnDQneoU6kecVbJ914gpNq7efvk4B8E0I597RAGl
    CDCb0r8VCCZ5AgMBAAGjUzBRMB0GA1UdDgQWBBTOnm7GrLwOlmPwl1bVxiwwWqRs
    ZjAfBgNVHSMEGDAWgBTOnm7GrLwOlmPwl1bVxiwwWqRsZjAPBgNVHRMBAf8EBTAD
    AQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAFNcpOGrZGbhH8gG3zL519lS2Fl56P9W0C
    Okxkz0OGiakVSCn3BCpgqVSGLsno3ktyLDlL2vb0WdIscrFJeu/ipv1J+G56TLfn
    etLOu+ahSGpCg4Czxx/BU+l8MRDd2wPGb/XQkmWg4xrSIXNI19s2H4k7EW97G79D
    BWcciy8t5kcxhB+xjReTIT8U7hoteuu9PazgAgZG6HwXM76olu4ZWDR3Y2TTR9v/
    0IXlyDe4DerJjES+61qZnL7KL7NQCaCAlKVC/P3RPOxY0urfddMDYB09DqrDPKhA
    mnA2Wj2vnYrBazCPRvFhg21zaHJuQr7n1wQh5erbzaIDNOuuiO0m
    -----END CERTIFICATE-----
    """
    |> String.replace(~r/^ +/m, "")
  end

  test "a fully configured environment reads cleanly" do
    # Guards against the whole suite below passing because the file raises
    # unconditionally.
    config = read_prod(%{})

    assert get_in(config, [:eft_buddy, EftBuddyWeb.Endpoint, :url, :host]) == "eftbuddy.example"
  end

  describe "every required variable must be present AND non-blank" do
    for name <- ~w(SECRET_KEY_BASE DATABASE_URL DB_PASSWORD PHX_HOST) do
      test "#{name} missing" do
        assert_raise RuntimeError, ~r/#{unquote(name)}.*missing/s, fn ->
          read_prod(%{unquote(name) => nil})
        end
      end

      # `||` only tests truthiness and `""` is truthy, so a blank value used to sail
      # straight through. That is not a hypothetical: it is what an env file line
      # reading `PHX_HOST=` produces, what a host's dashboard produces when the
      # field is saved empty, and what any templating layer produces for a
      # variable it could not resolve.
      test "#{name} blank" do
        assert_raise RuntimeError, ~r/#{unquote(name)}.*blank/s, fn ->
          read_prod(%{unquote(name) => ""})
        end
      end

      test "#{name} whitespace-only" do
        assert_raise RuntimeError, ~r/#{unquote(name)}.*blank/s, fn ->
          read_prod(%{unquote(name) => "   "})
        end
      end
    end
  end

  describe "PHX_HOST must be a bare hostname" do
    # `check_origin` compares this value verbatim against `URI.parse(origin).host`,
    # so every one of these rejects 100% of LiveView sockets while the page still
    # renders its static HTML and /health still answers 200 — the exact silent
    # failure the raise exists to prevent, reached with the variable legitimately set.
    for bad <- [
          "https://eftbuddy.example",
          "http://eftbuddy.example",
          "eftbuddy.example:443",
          "eftbuddy.example/",
          "eftbuddy.example/app",
          "user@eftbuddy.example",
          "eftbuddy.example?x=1",
          "two hosts"
        ] do
      test "rejects #{inspect(bad)}" do
        assert_raise RuntimeError, ~r/PHX_HOST must be a BARE hostname/, fn ->
          read_prod(%{"PHX_HOST" => unquote(bad)})
        end
      end
    end

    test "accepts a bare host, a subdomain and a trimmed value" do
      for good <- ["eftbuddy.example", "www.eftbuddy.example", "  eftbuddy.example  "] do
        config = read_prod(%{"PHX_HOST" => good})

        assert get_in(config, [:eft_buddy, EftBuddyWeb.Endpoint, :url, :host]) ==
                 String.trim(good)
      end
    end
  end

  describe "database TLS" do
    # `ssl: true` — the bare boolean this used to pass — negotiates a session
    # whose verification behaviour depends on the Postgrex version rather than on
    # anything stated in the config. Unverified TLS to a database reachable over
    # the public internet protects against passive sniffing only: nothing checks
    # that the peer presenting the certificate is the host we asked for. These
    # assert the verified shape is what actually reaches the Repo.
    test "off by default" do
      assert repo_ssl(read_prod(%{})) == false
    end

    test "DB_SSL=true verifies the peer, against the host from DATABASE_URL" do
      ssl = repo_ssl(read_prod(%{"DB_SSL" => "true"}))

      assert ssl[:verify] == :verify_peer
      # No pinned CA configured, so the OS trust store is the anchor.
      refute Keyword.has_key?(ssl, :cacertfile)
      # SNI must come from DATABASE_URL, not be hardcoded or omitted: managed
      # providers front many databases behind one address and serve the wrong
      # certificate without it.
      assert ssl[:server_name_indication] == ~c"127.0.0.1"
      assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
      assert is_function(ssl[:customize_hostname_check][:match_fun])
    end

    test "DB_SSL_INSECURE is a separate opt-in, so enabling TLS never disables verification" do
      # The escape hatch exists to isolate a certificate problem from a
      # connectivity problem in one restart. It must never be reachable by
      # setting DB_SSL alone.
      assert repo_ssl(read_prod(%{"DB_SSL" => "true", "DB_SSL_INSECURE" => "true"})) ==
               [verify: :verify_none]

      # And on its own it does nothing at all. DB_SSL is cleared EXPLICITLY:
      # `read_prod/1` only writes the variables it is handed, so without this it
      # would still be set from the assertion above and this would assert nothing.
      assert repo_ssl(read_prod(%{"DB_SSL" => nil, "DB_SSL_INSECURE" => "true"})) == false
    end

    test "DB_CACERTFILE pins that CA INSTEAD of the OS trust store" do
      # A database whose certificate chains to a root the OS does not ship cannot
      # be verified by `cacerts_get/0` at all, so verify_peer fails however correct
      # everything else is. Pinning is what makes verification possible.
      path = Path.join(System.tmp_dir!(), "eft_buddy_test_ca.crt")
      File.write!(path, test_root_pem())
      on_exit(fn -> File.rm(path) end)

      ssl = repo_ssl(read_prod(%{"DB_SSL" => "true", "DB_CACERTFILE" => path}))

      assert ssl[:cacertfile] == String.to_charlist(path)
      assert ssl[:verify] == :verify_peer

      # The point of the pin: the public CAs must NOT also be trusted alongside
      # it, or any of them could equally vouch for this host.
      refute Keyword.has_key?(ssl, :cacerts)
    end

    test "refuses to boot when DB_CACERTFILE names a file that is not there" do
      # A missing mount must name itself here rather than surface as an opaque
      # handshake failure inside Postgrex.
      assert_raise RuntimeError, ~r/could not be read/, fn ->
        read_prod(%{"DB_SSL" => "true", "DB_CACERTFILE" => "/nonexistent/pinned-ca.crt"})
      end
    end

    test "refuses to boot when DB_CACERTFILE is not actually a certificate" do
      # Not hypothetical: a CA fetched from a stale URL comes back as a 404 HTML
      # page, which saves under a `.crt` name perfectly happily. Accepting it
      # would fail much later and much less legibly.
      path = Path.join(System.tmp_dir!(), "eft_buddy_test_not_a_ca.crt")
      File.write!(path, "<!DOCTYPE html>\n<title>404 Not Found</title>\n")
      on_exit(fn -> File.rm(path) end)

      assert_raise RuntimeError, ~r/no PEM\s+certificate/, fn ->
        read_prod(%{"DB_SSL" => "true", "DB_CACERTFILE" => path})
      end
    end

    test "refuses to enable TLS when DATABASE_URL has no host to verify against" do
      # Silently falling back to an unverified session here would be the worst
      # outcome: TLS requested, nothing checked, no signal.
      assert_raise RuntimeError, ~r/no hostname could be parsed/, fn ->
        read_prod(%{"DB_SSL" => "true", "DATABASE_URL" => "ecto:///eft_buddy_shape_test"})
      end
    end
  end
end
