defmodule EftBuddy.Wiki.DumpScript do
  @moduledoc """
  Shared support for the wiki scrapers: the chapter sync
  (`EftBuddy.Chapters.Sync`) and the quest sync (`EftBuddy.Wiki.Sync`).

  Both need the same CLI/HTTP plumbing — a per-process throttle, SSL
  options, the MediaWiki API call with retries, and category-member
  enumeration — so it lives here in one place rather than being
  copy-pasted (which is how the old quest + chapter scripts drifted
  apart). Dependency-light (only `Req` + `Jason`) so it still works under
  `mix run --no-start` in any ad-hoc script as well as inside the app.
  """

  require Logger

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
  @user_agent "EFT-Buddy/0.1 (+https://github.com/joaoaraujo1511/EFT-Buddy)"

  @api_throttle_ms 250
  # Transient-failure retry budget for the wiki API. Fandom rate-limits
  # long scrapes with intermittent 503s (carrying a Retry-After header
  # that Req honours); a generous budget keeps a 503 burst from dropping
  # a page entirely. Retries only fire on failure, so this costs nothing
  # on the happy path.
  @api_max_retries 4

  # ── CLI ─────────────────────────────────────────────────────────────

  @doc """
  Parse `--key value` and `--flag` style args. Anything not starting
  with `--` is positional (the scripts treat the first positional as the
  output directory).

  `integer_keys` lists flag keys whose values should be cast to integers
  (e.g. `[:limit]` for the quest script's `--limit N`); every other
  value is kept as a string. Returns `{keyword_flags, positional_args}`.
  """
  @spec parse_args([String.t()], [atom()]) :: {keyword(), [String.t()]}
  def parse_args(argv, integer_keys \\ []) when is_list(argv) and is_list(integer_keys) do
    do_parse(argv, integer_keys, [], [])
  end

  # sobelow_skip ["DOS.StringToAtom"]
  defp do_parse([], _int_keys, flags, positional),
    do: {Enum.reverse(flags), Enum.reverse(positional)}

  # sobelow_skip ["DOS.StringToAtom"]
  defp do_parse([arg | rest], int_keys, flags, positional) do
    if String.starts_with?(arg, "--") do
      key =
        arg
        |> String.replace_prefix("--", "")
        |> String.replace("-", "_")
        |> String.to_atom()

      case rest do
        [next | rest2] ->
          if String.starts_with?(next, "--") do
            do_parse(rest, int_keys, [{key, true} | flags], positional)
          else
            do_parse(rest2, int_keys, [{key, cast(key, next, int_keys)} | flags], positional)
          end

        [] ->
          do_parse([], int_keys, [{key, true} | flags], positional)
      end
    else
      do_parse(rest, int_keys, flags, [arg | positional])
    end
  end

  defp cast(key, value, int_keys) do
    if key in int_keys, do: String.to_integer(value), else: value
  end

  # ── Console helpers (ANSI) ──────────────────────────────────────────

  def header(text) do
    IO.puts("")

    IO.puts(
      IO.ANSI.cyan() <>
        "── #{text} " <>
        String.duplicate("─", max(0, 60 - String.length(text))) <>
        IO.ANSI.reset()
    )
  end

  def ok(label, detail \\ nil) do
    line = IO.ANSI.green() <> "  [OK]   " <> IO.ANSI.reset() <> label

    line =
      if detail, do: line <> " — " <> IO.ANSI.faint() <> detail <> IO.ANSI.reset(), else: line

    IO.puts(line)
  end

  def warn(label, detail \\ nil) do
    line = IO.ANSI.yellow() <> "  [WARN] " <> IO.ANSI.reset() <> label
    line = if detail, do: line <> " — " <> detail, else: line
    IO.puts(line)
  end

  def fail(label, detail \\ nil) do
    line = IO.ANSI.red() <> "  [FAIL] " <> IO.ANSI.reset() <> label
    line = if detail, do: line <> " — " <> detail, else: line
    IO.puts(line)
  end

  def info(label, detail) do
    IO.puts("  " <> IO.ANSI.faint() <> "        " <> IO.ANSI.reset() <> label <> ": " <> detail)
  end

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
    throttle_ms = Keyword.get(opts, :throttle_ms, @api_throttle_ms)
    max_retries = Keyword.get(opts, :max_retries, @api_max_retries)

    throttle(throttle_ms)

    result =
      Req.get(url,
        params: params,
        headers: [{"user-agent", user_agent}, {"accept", "application/json"}],
        receive_timeout: receive_timeout,
        connect_options: ssl_connect_options(),
        retry: :transient,
        max_retries: max_retries,
        retry_log_level: :debug
      )

    case result do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Category enumeration ────────────────────────────────────────────

  @doc """
  Walk a MediaWiki category and return the de-duplicated, sorted list of
  member page titles.

  Uses `cmtype=page` so subcategories are excluded, and follows
  `cmcontinue` pagination (categories are small today, but this won't
  silently truncate if one grows). On a failed request it returns
  whatever was collected so far — an **empty** list is the agreed "could
  not enumerate" signal, which both sync callers turn into a loud "keep
  existing rows" rather than pruning everything.
  """
  @spec enumerate_category_members(String.t(), keyword()) :: [String.t()]
  def enumerate_category_members(category, http_opts)
      when is_binary(category) and is_list(http_opts) do
    category
    |> fetch_category_members(nil, MapSet.new(), http_opts)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp fetch_category_members(category, cmcontinue, acc, http_opts) do
    params = %{
      "action" => "query",
      "list" => "categorymembers",
      "cmtitle" => category,
      "cmlimit" => "500",
      "cmtype" => "page",
      "format" => "json",
      "formatversion" => "2"
    }

    params = if cmcontinue, do: Map.put(params, "cmcontinue", cmcontinue), else: params

    case api_get(params, http_opts) do
      {:ok, body} ->
        acc =
          (get_in(body, ["query", "categorymembers"]) || [])
          |> Enum.reduce(acc, fn %{"title" => title}, set -> MapSet.put(set, title) end)

        case get_in(body, ["continue", "cmcontinue"]) do
          nil -> acc
          next -> fetch_category_members(category, next, acc, http_opts)
        end

      {:error, reason} ->
        Logger.warning("[DumpScript] enumeration of #{category} failed: #{inspect(reason)}")
        acc
    end
  end

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
