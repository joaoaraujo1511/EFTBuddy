defmodule EftBuddy.Sync.HelpersTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Sync.Helpers

  describe "now_naive/0" do
    test "returns a second-precision NaiveDateTime" do
      ndt = Helpers.now_naive()
      assert %NaiveDateTime{} = ndt
      assert ndt.microsecond == {0, 0}
    end
  end

  describe "to_float/1" do
    test "passes floats through unchanged" do
      assert Helpers.to_float(1.5) === 1.5
    end

    test "coerces integers to float" do
      assert Helpers.to_float(3) === 3.0
    end

    test "nil and non-numeric values become nil" do
      assert Helpers.to_float(nil) == nil
      assert Helpers.to_float("12") == nil
      assert Helpers.to_float(%{}) == nil
    end
  end

  describe "slugify/1" do
    test "lowercases and collapses non-alphanumerics to single dashes" do
      assert Helpers.slugify("Health Skill") == "health-skill"
      assert Helpers.slugify("Golden Zibbo") == "golden-zibbo"
    end

    test "trims leading/trailing dashes and collapses runs of punctuation" do
      assert Helpers.slugify("  Hello,  World!  ") == "hello-world"
    end

    test "nil passes through" do
      assert Helpers.slugify(nil) == nil
    end

    test "a string with no alphanumerics becomes empty" do
      assert Helpers.slugify("---") == ""
      assert Helpers.slugify("") == ""
    end
  end

  describe "cleanup_safe?/3 (partial-snapshot guard)" do
    test "cold start (no existing rows) always proceeds" do
      assert Helpers.cleanup_safe?(0, 0) == :ok
      assert Helpers.cleanup_safe?(0, 5) == :ok
    end

    test "a healthy snapshot (same size or larger) proceeds" do
      assert Helpers.cleanup_safe?(100, 100) == :ok
      assert Helpers.cleanup_safe?(100, 250) == :ok
      # exactly at the default 90% floor is allowed
      assert Helpers.cleanup_safe?(100, 90) == :ok
    end

    test "a suspiciously small snapshot is refused" do
      assert {:skip, reason} = Helpers.cleanup_safe?(100, 89)
      assert reason =~ "partial"
      assert {:skip, _} = Helpers.cleanup_safe?(3000, 100)
      assert {:skip, _} = Helpers.cleanup_safe?(10, 0)
    end

    # The floor used to be 0.5, which accepted a snapshot carrying half the
    # catalogue and deleted the rest. Pinned so a future "this seems strict"
    # edit has to argue with a test rather than a comment.
    test "a HALVED catalogue is refused at the default floor" do
      assert {:skip, _} = Helpers.cleanup_safe?(100, 50)
    end

    test "the keep ratio is configurable" do
      # Explicitly the OLD default, so this proves the knob works rather than
      # accidentally re-asserting whatever the current default happens to be.
      assert Helpers.cleanup_safe?(100, 50, 0.5) == :ok
      assert {:skip, _} = Helpers.cleanup_safe?(100, 49, 0.5)
    end
  end

  describe "prices_safe?/3 (null-stripped-snapshot guard)" do
    test "cold start (nothing currently priced) always proceeds" do
      # A fresh node has no priced rows to protect, and blocking here would mean
      # the price layer could never populate at all.
      assert Helpers.prices_safe?(0, 0) == :ok
      assert Helpers.prices_safe?(0, 5_000) == :ok
    end

    test "a snapshot carrying as many prices as we hold proceeds" do
      assert Helpers.prices_safe?(5_000, 5_000) == :ok
      assert Helpers.prices_safe?(5_000, 5_200) == :ok
      # exactly at the default 90% floor is allowed
      assert Helpers.prices_safe?(5_000, 4_500) == :ok
    end

    test "a document that lost most of its prices is refused" do
      assert {:skip, reason} = Helpers.prices_safe?(5_000, 4_499)
      assert reason =~ "null-stripped"
    end

    test "a full-size document with EVERY price nulled is refused" do
      # The failure this guard exists for, and the one a row-count check cannot
      # see: the response still lists all ~5,200 items, so nothing about its SIZE
      # is anomalous. Only the count of *priced* rows moves — to zero.
      assert {:skip, _} = Helpers.prices_safe?(5_000, 0)
    end

    test "an empty document is refused rather than silently writing nothing" do
      # Deliberately a change of behaviour. An empty response used to produce zero
      # rows and a run that reported `ok` with `upserted: 0` — a real upstream
      # failure that reached nobody. It is the same input as the case above.
      assert {:skip, _} = Helpers.prices_safe?(5_000, 0)
    end

    test "the keep ratio is the same knob cleanup_safe?/3 uses" do
      assert Helpers.prices_safe?(100, 50, 0.5) == :ok
      assert {:skip, _} = Helpers.prices_safe?(100, 49, 0.5)
    end
  end

  describe "retry_transient?/2" do
    setup do
      %{request: %Req.Request{}}
    end

    test "retries on a transient HTTP status", %{request: req} do
      for status <- [408, 429, 500, 502, 503, 504] do
        resp = %Req.Response{status: status, body: %{}}
        assert Helpers.retry_transient?(req, resp), "expected #{status} to retry"
      end
    end

    test "does not retry a successful or other non-transient response", %{request: req} do
      refute Helpers.retry_transient?(req, %Req.Response{status: 200, body: %{}})
      refute Helpers.retry_transient?(req, %Req.Response{status: 404, body: %{}})
    end

    test "does NOT retry a Cloudflare 1102 worker-limit 503 (retryable: false)", %{request: req} do
      # The exact shape tarkov.dev returns when its Worker exceeds its budget.
      cloudflare = %Req.Response{
        status: 503,
        body: %{
          "cloudflare_error" => true,
          "error_code" => 1102,
          "retryable" => false,
          "title" => "Error 1102: Worker exceeded resource limits"
        }
      }

      refute Helpers.retry_transient?(req, cloudflare)
    end

    test "does not retry any body that self-reports retryable: false", %{request: req} do
      refute Helpers.retry_transient?(req, %Req.Response{
               status: 503,
               body: %{"retryable" => false}
             })

      refute Helpers.retry_transient?(req, %Req.Response{status: 502, body: %{retryable: false}})
    end

    # The retry step runs before Req decodes/decompresses the body, so in
    # production `response.body` is a raw binary — identity JSON or gzip'd
    # JSON — not a map. These are the cases that actually reach the predicate.
    test "does NOT retry a raw (undecoded) JSON-string Cloudflare body", %{request: req} do
      raw =
        Jason.encode!(%{"cloudflare_error" => true, "retryable" => false, "error_code" => 1102})

      refute Helpers.retry_transient?(req, %Req.Response{status: 503, body: raw})
    end

    test "does NOT retry a gzip-compressed Cloudflare body", %{request: req} do
      gzipped =
        %{"cloudflare_error" => true, "retryable" => false}
        |> Jason.encode!()
        |> :zlib.gzip()

      refute Helpers.retry_transient?(req, %Req.Response{status: 503, body: gzipped})
    end

    test "still retries a raw/gzip'd 503 body with no non-retryable flag", %{request: req} do
      raw = Jason.encode!(%{"detail" => "temporarily unavailable"})
      gzipped = raw |> :zlib.gzip()
      assert Helpers.retry_transient?(req, %Req.Response{status: 503, body: raw})
      assert Helpers.retry_transient?(req, %Req.Response{status: 503, body: gzipped})
    end

    test "retries an unparseable body (e.g. HTML error page or unknown encoding)",
         %{request: req} do
      assert Helpers.retry_transient?(req, %Req.Response{status: 503, body: "<html>oops</html>"})
      assert Helpers.retry_transient?(req, %Req.Response{status: 503, body: <<0, 1, 2, 3>>})
    end

    test "still retries a bare 503 with no non-retryable flag (e.g. Fandom rate-limit)",
         %{request: req} do
      assert Helpers.retry_transient?(req, %Req.Response{status: 503, body: %{"detail" => "busy"}})

      assert Helpers.retry_transient?(req, %Req.Response{status: 503, body: "<html>busy</html>"})

      assert Helpers.retry_transient?(req, %Req.Response{
               status: 503,
               body: %{"retryable" => true}
             })
    end

    test "retries the transient transport/HTTP-2 errors", %{request: req} do
      for reason <- [:timeout, :econnrefused, :closed] do
        assert Helpers.retry_transient?(req, %Req.TransportError{reason: reason})
      end

      assert Helpers.retry_transient?(req, %Req.HTTPError{protocol: :http2, reason: :unprocessed})
    end

    test "does not retry other exceptions", %{request: req} do
      refute Helpers.retry_transient?(req, %Req.TransportError{reason: :nxdomain})
      refute Helpers.retry_transient?(req, %RuntimeError{message: "boom"})
    end
  end
end
