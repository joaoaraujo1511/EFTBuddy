defmodule EftBuddyWeb.ProdConfigTest do
  @moduledoc """
  Pins the parts of production configuration that nothing else can see.

  Two live defects came from here, and both were **invisible**:

    * `force_ssl:`'s `exclude:` sat as a SIBLING key in the Endpoint's config rather
      than nested inside `force_ssl:`, so `Plug.SSL` never received it. Phoenix
      ignores unknown endpoint config keys, which is precisely why it survived — and
      why reverting it would be silent again.
    * `PHX_HOST` defaulted to `"example.com"`, poisoning `check_origin` for every
      LiveView socket while `/health` still answered 200.

  Neither is reachable from the test environment: `config/test.exs` sets no
  `force_ssl`, so `plug Plug.SSL` is not even compiled into the test endpoint, and
  `config/runtime.exs`'s prod branch never runs. So this reads the config FILE
  directly with `Config.Reader`, which is the only way to make a regression here
  fail anything.
  """
  use ExUnit.Case, async: true

  @prod_config Path.join([__DIR__, "..", "..", "config", "prod.exs"]) |> Path.expand()

  defp force_ssl_opts do
    @prod_config
    |> Config.Reader.read!(env: :prod)
    |> get_in([:eft_buddy, EftBuddyWeb.Endpoint, :force_ssl])
  end

  defp excluded_paths do
    force_ssl_opts() |> Keyword.fetch!(:exclude) |> Keyword.get(:paths, [])
  end

  describe "force_ssl in config/prod.exs" do
    test "is set at all" do
      assert is_list(force_ssl_opts()), "prod must redirect http:// to https://"
    end

    test "carries its exclusions NESTED inside force_ssl, where Plug.SSL will see them" do
      # THE REGRESSION. `exclude:` as a sibling of `force_ssl:` is accepted silently
      # by Phoenix and dropped on the floor, so the health-check exemption did
      # nothing and a load-balancer probe over plain HTTP got a 301 before it ever
      # reached the router.
      assert Keyword.has_key?(force_ssl_opts(), :exclude),
             "exclude: must be nested inside force_ssl:, not a sibling of it"
    end

    test "is a shape Plug.SSL itself accepts" do
      # `Plug.SSL.validate_exclude!/1` is the authority on the option shape, and it
      # has changed over time: a bare list of host strings is the DEPRECATED form and
      # the keyword form (`paths:` / `hosts:` / `conn:`) is current. Rather than
      # encode either belief here, hand the real options to the real function — it
      # raises on anything it will not accept.
      assert Plug.SSL.init(force_ssl_opts())
    end

    test "exempts exactly the health routes the router declares" do
      # A path exemption naming a route the router does not have is worse than none:
      # it reads as protection and provides none.
      declared =
        EftBuddyWeb.Router.__routes__()
        |> Enum.filter(&(&1.verb == :get and &1.plug == EftBuddyWeb.HealthController))
        |> Enum.map(& &1.path)
        |> Enum.sort()

      assert declared != [], "sanity: the router must declare at least one health route"

      assert declared == Enum.sort(excluded_paths()),
             "every health route must be exempt from the HTTPS redirect, and nothing else"
    end

    test "path exemptions are matched before the redirect, not after" do
      # The exemption is only useful if `Plug.SSL` checks it BEFORE rewriting to
      # https. Prove it against the real plug rather than trusting the ordering:
      # drive an http:// request at an excluded path and assert it is untouched.
      opts = Plug.SSL.init(force_ssl_opts())

      for path <- excluded_paths() do
        conn = Plug.SSL.call(%{Plug.Test.conn(:get, path) | scheme: :http}, opts)

        refute conn.halted, "#{path} must not be redirected to https"
        assert conn.status == nil
      end

      # ...and that a normal path still is, so the test above cannot pass because the
      # plug is inert.
      redirected = Plug.SSL.call(%{Plug.Test.conn(:get, "/tasks") | scheme: :http}, opts)

      assert redirected.halted
      assert redirected.status == 301
    end
  end

  describe "the LiveView socket" do
    test "bounds a single client frame, above what Progress will accept" do
      # The memory bound is `EftBuddy.Progress`' per-slice cap; this only has to stop
      # an absurd frame before it is decoded. It must nonetheless sit comfortably
      # ABOVE what `Progress` accepts, or a legitimate blob could never arrive: the
      # socket would close 1009, LiveView would reconnect, the `Hud` hook would
      # re-push the identical frame, and the page would be permanently unusable with
      # nothing in the logs.
      {"/live", _mod, socket_opts} =
        EftBuddyWeb.Endpoint.__sockets__()
        |> Enum.find(&match?({"/live", _, _}, &1))

      max_frame = socket_opts |> Keyword.fetch!(:websocket) |> Keyword.fetch!(:max_frame_size)

      assert max_frame > 2 * EftBuddy.Progress.max_slice_bytes(),
             "max_frame_size must exceed both mode slices at their ceiling"
    end
  end
end
