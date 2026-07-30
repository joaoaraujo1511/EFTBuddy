defmodule EftBuddy.Sync.ReporterTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Sync.Reporter

  describe "describe_error/1" do
    test "collapses a Cloudflare unexpected_response into a single line" do
      body = %{
        "title" => "Error 1102: Worker exceeded resource limits",
        "retryable" => false,
        "zone" => "api.tarkov.dev",
        "ray_id" => "abc123",
        "detail" => "A Worker script ... was terminated."
      }

      assert Reporter.describe_error({:unexpected_response, 503, body}) ==
               "HTTP 503 from api.tarkov.dev — Error 1102: Worker exceeded resource limits (non-retryable)"
    end

    test "omits the non-retryable note unless retryable is explicitly false" do
      body = %{"title" => "Error 500", "zone" => "api.tarkov.dev"}

      assert Reporter.describe_error({:unexpected_response, 503, body}) ==
               "HTTP 503 from api.tarkov.dev — Error 500"
    end

    test "falls back to a bare status for a thin or non-map body" do
      assert Reporter.describe_error({:unexpected_response, 502, %{"foo" => "bar"}}) == "HTTP 502"

      assert Reporter.describe_error({:unexpected_response, 500, "<html>oops</html>"}) ==
               "HTTP 500"
    end

    test "summarises a crash" do
      assert Reporter.describe_error({:crash, "boom"}) == "crash — boom"
    end

    test "summarises a missing translation document by its path" do
      assert Reporter.describe_error({:invalid_locale, "/pve/items_en"}) ==
               "missing or invalid translation document /pve/items_en"
    end

    test "summarises a JSON decode failure" do
      assert Reporter.describe_error({:json_decode_failed, {:error, :badarg}}) ==
               "response body was not valid JSON"
    end

    test "summarises a partial result, naming the ok and failed modes" do
      partial =
        {:partial, %{"regular" => %{maps: 13, tasks: 510, objectives: 1485, unlocks: 607}},
         [
           {"pve",
            {:unexpected_response, 503,
             %{
               "title" => "Error 1102: Worker exceeded resource limits",
               "retryable" => false,
               "zone" => "api.tarkov.dev"
             }}}
         ]}

      assert Reporter.describe_error(partial) ==
               "regular ok (510 tasks); pve failed (HTTP 503 from api.tarkov.dev — " <>
                 "Error 1102: Worker exceeded resource limits (non-retryable))"
    end

    test "renders the already-running sentinel" do
      assert Reporter.describe_error(:already_running) == "another sync is already running"
    end

    test "caps an unrecognised oversized term to one truncated line" do
      out = Reporter.describe_error({:weird, String.duplicate("x", 1_000)})

      assert String.length(out) <= 301
      assert String.ends_with?(out, "…")
    end
  end
end
