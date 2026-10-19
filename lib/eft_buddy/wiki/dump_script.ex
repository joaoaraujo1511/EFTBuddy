defmodule EftBuddy.Wiki.DumpScript do
  @moduledoc """
  The HTTP transport under `EftBuddy.Wiki.Api`, which every wiki scraper (the
  quest, chapter and events syncs) calls: a per-process throttle, SSL options,
  the user agent, and one MediaWiki API GET with retries that turns an error
  body into `{:error, _}`.

  The name is historical: this began as the support module for the offline
  dump scripts the syncs replaced. Their CLI parsing and console output went
  with them (audit L5).
  """

  # MediaWiki's user-agent policy asks automated clients to identify
  # themselves and give a way to be contacted about their traffic. This
  # points at the public repository rather than a mailto: the issue tracker
  # is reachable by anyone, and it cannot silently bounce the way the
  # placeholder address this replaced did.
  #
  # It matters more here than for a typical scraper: we render this wiki's
  # prose under CC BY-NC-SA, where attribution is a condition of the grant,
  # so being identifiable to the people whose work we depend on is the
  # minimum courtesy — and the thing that lets them reach us if our traffic
  # is ever a problem.
  @user_agent "EFT-Buddy/0.1 (+https://github.com/joaoaraujo1511/EFTBuddy)"

  @api_throttle_ms 250
  # Transient-failure retry budget for the wiki API. Fandom rate-limits
  # long scrapes with intermittent 503s (carrying a Retry-After header
  # that Req honours); a generous budget keeps a 503 burst from dropping
  # a page entirely. Retries only fire on failure, so this costs nothing
  # on the happy path.
  @api_max_retries 4

  # ── HTTP layer ──────────────────────────────────────────────────────

  @doc """
  Issue a throttled, retrying MediaWiki API GET and return
  `{:ok, decoded_body} | {:error, reason}`.

  This is a quiet transport: it emits **no** per-request log lines.
  Per-request logging on a daily scrape buries everything else, so
  callers running inside a `EftBuddy.Sync.Reporter.with_run/2` instead
  fold failures into that run's `warnings`/`errors` count via
  `Reporter.silent_warn/1`, and the run is bracketed by a single
  start/stop summary. Transient retries are logged at `:debug` (dropped
  at the production `:info` level, visible in dev).

  Options:

    * `:url`              — required, the api.php endpoint
    * `:user_agent`       — required
    * `:receive_timeout`  — per-request receive timeout in ms (default 30s)
    * `:throttle_ms`      — minimum spacing between requests (default 250ms)
    * `:max_retries`      — transient-failure retries (default 4)

  ## On the 503s

  The Fandom MediaWiki API rate-limits sustained bursts: under a long
  scrape it intermittently answers `503 Service Unavailable` with a
  `Retry-After` header. `Req`'s `retry: :transient` honours that header
  (hence the "will retry in 5000ms" debug lines) and the request almost
  always succeeds on the next attempt. We keep a healthy retry budget so
  a 503 burst doesn't surface as a failed page (a quest that fails to
  fetch on a cold start gets no row written at all, so it'd silently miss
  from the tab until the next daily run). The two wiki scrapers are also
  scheduled apart (see `EftBuddy.Chapters.Sync` / `EftBuddy.Wiki.Sync`)
  so they don't double the request rate by running concurrently.
  """
  def api_get(params, opts) when is_map(params) and is_list(opts) do
    url = Keyword.fetch!(opts, :url)
    user_agent = Keyword.fetch!(opts, :user_agent)
    receive_timeout = Keyword.get(opts, :receive_timeout, 30_000)

    throttle_ms =
      Keyword.get(
        opts,
        :throttle_ms,
        Application.get_env(:eft_buddy, :wiki_throttle_ms, @api_throttle_ms)
      )

    max_retries = Keyword.get(opts, :max_retries, @api_max_retries)

    throttle(throttle_ms)

    req_options =
      Keyword.merge(
        [
          params: params,
          headers: [{"user-agent", user_agent}, {"accept", "application/json"}],
          receive_timeout: receive_timeout,
          connect_options: ssl_connect_options(),
          retry: :transient,
          max_retries: max_retries,
          retry_log_level: :debug
        ],
        # Test only: routes every wiki request to a `Req.Test` stub
        # (see config/test.exs), the way `:tarkov_req_options` does for tarkov.dev.
        Application.get_env(:eft_buddy, :wiki_req_options, [])
      )

    url |> Req.get(req_options) |> interpret()
  end

  # MediaWiki reports a failed request as HTTP 200 with an `error` body
  # (`missingtitle`, `ratelimited`, `internal_api_error_*`). Those used to count
  # as successful empty results, and the licence lookup then cached "this file
  # declares no licence" for seven days (audit M19). Decided once, here, so no
  # caller has to remember to look.
  defp interpret({:ok, %{status: 200, body: body}}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> interpret({:ok, %{status: 200, body: decoded}})
      _ -> {:error, {:invalid_body, String.slice(body, 0, 200)}}
    end
  end

  defp interpret({:ok, %{status: 200, body: %{"error" => error}}}) when is_map(error),
    do: {:error, {:api, error["code"], error["info"]}}

  defp interpret({:ok, %{status: 200, body: body}}) when is_map(body), do: {:ok, body}

  defp interpret({:ok, %{status: 200, body: body}}),
    do: {:error, {:invalid_body, inspect(body, limit: 20)}}

  defp interpret({:ok, %{status: status, body: body}}), do: {:error, {:http, status, body}}
  defp interpret({:error, reason}), do: {:error, reason}

  @doc """
  The user-agent every wiki request identifies itself with.

  Shared by all three scrapers so the contact details cannot go stale in one
  of them while staying current in the others.
  """
  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent

  @doc """
  Build a function mapping an API-returned page title back to the title
  that was *requested*.

  MediaWiki normalises titles (underscores to spaces, first letter cased)
  and, with `redirects=1`, resolves redirects — so the `title` on a page in
  the response is not necessarily the string the caller asked for. Any code
  that keys its result by the returned title and is then looked up by the
  requested title will silently miss.

  Pass the whole response body; the returned function walks the
  `normalized` and `redirects` chains backwards. Redirects can chain, hence
  the bounded loop rather than a single lookup. Titles with no rewrite come
  back unchanged, which is the overwhelmingly common case.

      resolver = DumpScript.requested_title_resolver(body)
      resolver.("Some Normalised Title")
      #=> "some_normalised title"
  """
  @spec requested_title_resolver(map()) :: (String.t() -> String.t())
  def requested_title_resolver(body) when is_map(body) do
    rewrites =
      ((get_in(body, ["query", "normalized"]) || []) ++
         (get_in(body, ["query", "redirects"]) || []))
      |> Enum.reduce(%{}, fn
        %{"from" => from, "to" => to}, acc -> Map.put(acc, to, from)
        _, acc -> acc
      end)

    fn title ->
      Enum.reduce_while(1..5, title, fn _, current ->
        case Map.get(rewrites, current) do
          nil -> {:halt, current}
          previous -> {:cont, previous}
        end
      end)
    end
  end

  def ssl_connect_options do
    base = [timeout: 10_000]

    transport =
      if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
        [
          transport_opts: [
            cacertfile: String.to_charlist(apply(CAStore, :file_path, [])),
            verify: :verify_peer,
            depth: 4
          ]
        ]
      else
        []
      end

    base ++ transport
  end

  # Ensure ≥`throttle_ms` between consecutive API calls. The first call
  # on a fresh process must NOT sleep — seed `:last_request_at` to one
  # full interval in the past so `now - last == throttle_ms` and the
  # wait is zero (fixes the prior off-by-one that slept before request 1).
  def throttle(throttle_ms \\ @api_throttle_ms) do
    now = System.monotonic_time(:millisecond)
    last = Process.get(:last_request_at, now - throttle_ms)
    wait = throttle_ms - (now - last)
    if wait > 0, do: Process.sleep(wait)
    Process.put(:last_request_at, System.monotonic_time(:millisecond))
  end
end
