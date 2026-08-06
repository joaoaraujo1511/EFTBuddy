defmodule EftBuddy.Sync.Reporter do
  @moduledoc """
  Per-sync-run instrumentation: collapses the per-query Ecto log
  spam into a single summary line, with op-type counts, affected
  rows, and timings.

  ## Why

  Each sync module (`Items.Sync`, `Hideout.Sync`, `Tasks.Sync`)
  issues hundreds-to-thousands of `INSERT` / `DELETE` / `UPDATE`
  / `SELECT` statements per run. With Ecto's default per-query
  logger this turns the console into a wall of `QUERY OK INSERT
  INTO …` lines that hide the surrounding `Logger.info` summary
  lines we actually wrote ourselves.

  Disabling Ecto's per-query log entirely would remove valuable
  dev info during normal request handling. Instead, we:

    1. Set `config :eft_buddy, EftBuddy.Repo, log: false` so
       Ecto's built-in handler stays out of the way.
    2. Attach our own permanent handler on the Repo's query
       telemetry event. When we're **inside** a sync run (a
       process-dict flag is set by `with_run/2`), the handler
       just increments counters. **Outside** a run, the handler
       emits an Ecto-style debug log so dev request logs still
       show up.

  Ecto always emits the telemetry event regardless of `:log`, so
  our counters work the same in dev and prod.

  ## Usage

  Wrap a sync function and you get a `starting…` line up front and one
  summary line at the end, bracketing the run:

      Reporter.with_run("ItemsSync", fn ->
        # …existing pipeline; same return value passes through…
      end)

  Returns whatever `fun` returned.

  Use `silent_warn/1` for known per-row warnings (e.g. an FK
  target that resolves on the next sync) — it bumps the
  warning counter without spamming the log:

      Reporter.silent_warn("[HideoutSync] Skipping item req: \#{id}")

  ## Output format

      [ItemsSync] starting…
      [ItemsSync] ok in 12.42s — SELECT 18, INSERT 47 (94213 rows),
                 UPDATE 312 (5274 rows), DELETE 11 (8402 rows), OTHER 2
                 — warnings=0 errors=0

  Operations with zero executions are omitted. Row counts are
  shown when meaningful (INSERT / DELETE always; UPDATE if > 0).
  Per-op timings are intentionally not rendered — the total
  elapsed at the start of the line is enough; per-op timing
  added clutter without surfacing useful debugging signal.
  """

  require Logger

  @counters_key :sync_reporter_counters
  @run_label_key :sync_reporter_label
  @op_order [:select, :insert, :update, :delete, :other]
  @telemetry_handler_id "eft-buddy-sync-reporter"
  @telemetry_event [:eft_buddy, :repo, :query]
  # Table holding the last run outcome per sync label, so an operator
  # (or the /health endpoint) can answer "when did each sync last
  # succeed?" without scraping logs.
  @status_table :eft_buddy_sync_status

  # ── Module-name → ANSI color ──────────────────────────
  #
  # Bootstrap (orchestrator) gets its own color so the
  # "phase boundary" lines pop visually. All data-sync
  # modules share a single color: per-module colors looked
  # busy in practice and the SELECT/INSERT/UPDATE/DELETE
  # coloring inside each summary line already gives the eye
  # plenty of structure. Cyan is readable on light *and*
  # dark backgrounds. Swap values here to retheme.
  @label_colors %{
    "Bootstrap" => :magenta,
    "Sync" => :cyan,
    "ItemsSync" => :cyan,
    "PricesSync" => :cyan,
    "FleaSettingsSync" => :cyan,
    "QuestItemsSync" => :cyan,
    "BartersSync" => :cyan,
    "CraftsSync" => :cyan,
    "HideoutSync" => :cyan,
    "TasksSync" => :cyan,
    "MapsSync" => :cyan,
    "WikiSync" => :cyan,
    "ChaptersSync" => :cyan
  }

  # Fallback color for any bracketed tag we don't have an explicit entry
  # for — including mode-suffixed labels (`TasksSync:pve`) and ad-hoc
  # tags from shared infra. Cyan matches the data-sync family above, so
  # an unmapped label is still colorized consistently instead of
  # printing uncolored against its colored neighbours.
  @default_label_color :cyan

  # ── SQL-op → ANSI color ────────────────────────────────
  #
  # Using the standard "data-mutation severity" palette
  # familiar from DB GUI tools (Postico, DataGrip, etc.):
  # blue for safe reads, green for additive writes, yellow
  # for in-place modifications, red for destruction. OTHER
  # is left uncolored — if it ever shows up in volume we
  # want it to stand out by *being* uncolored against the
  # rest of the line.
  @op_colors %{
    select: :blue,
    insert: :green,
    update: :yellow,
    delete: :red
  }

  # ── Setup (called once at app start) ───────────────────

  @doc """
  Attach the telemetry handler. Idempotent: a duplicate-handler
  error from `:telemetry.attach/4` is treated as success so the
  app can be restarted in IEx without crashing.
  """
  def attach_telemetry do
    ensure_status_table()

    case :telemetry.attach(
           @telemetry_handler_id,
           @telemetry_event,
           &__MODULE__.handle_query_event/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # Public ETS table keyed by sync label → last-run status map. Created
  # once at app start; idempotent so IEx restarts don't crash.
  defp ensure_status_table do
    if :ets.whereis(@status_table) == :undefined do
      :ets.new(@status_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Last recorded run status for every sync label, as a map of

      %{label => %{outcome: :ok | :error | :skipped | :done,
                   at: DateTime.t(),
                   last_ok_at: DateTime.t() | nil,
                   duration_ms: non_neg_integer(),
                   refusals: non_neg_integer(),
                   consecutive_skips: non_neg_integer()}}

  `at` is when the label last ran; `last_ok_at` is when it last ran *successfully*
  and is `nil` for a label that has never succeeded since boot. `EftBuddy.Sync.Freshness`
  ages on the latter — see `record_status/4`.

  Empty before any sync has run. Backs the `/health` readiness check.
  """
  def status do
    case :ets.whereis(@status_table) do
      :undefined -> %{}
      _ -> @status_table |> :ets.tab2list() |> Map.new()
    end
  end

  @doc """
  Seconds since the most recent *successful* run across all syncs, or
  `nil` if none has succeeded since boot. Useful as a single freshness
  gauge.
  """
  def seconds_since_last_success do
    status()
    |> Enum.filter(fn {_label, s} -> s.outcome == :ok end)
    |> Enum.map(fn {_label, s} -> s.at end)
    |> case do
      [] -> nil
      times -> DateTime.diff(DateTime.utc_now(), Enum.max(times, DateTime))
    end
  end

  @doc """
  Forget every recorded run outcome.

  Two callers. From IEx, after fixing whatever made a sync fail, so
  `EftBuddyWeb.LoadState` stops showing a fault marker and `/health/sync` stops
  reporting degraded without waiting for the next scheduled run.

  And from tests, because this table is **global, named and public** — the one piece
  of cross-test shared state in the app. A test that records a failed run changes
  what unrelated LiveViews render (`LoadState.resolve/2` reads it, so an `:error`
  outcome turns a page's standby panel into a fault marker) and makes
  `/health/sync` answer 503. Any test that writes a run must reset afterwards.
  """
  @spec reset_status() :: :ok
  def reset_status do
    ensure_status_table()
    :ets.delete_all_objects(@status_table)
    :ok
  end

  @doc false
  # Invoked by `:telemetry_poller` (see `EftBuddyWeb.Telemetry`).
  #
  # The `[:eft_buddy, :sync, :stop]` event already fires once per run, which is
  # enough to chart durations but useless for the question an operator actually
  # asks: "is anything STALE?" A sync that stopped running emits nothing at all, so
  # its absence is invisible to an event-driven metric. Age has to be *polled* to
  # be observable — one gauge per label, climbing until the next successful run
  # resets it.
  def emit_freshness do
    now = DateTime.utc_now()

    Enum.each(status(), fn {label, s} ->
      :telemetry.execute(
        [:eft_buddy, :sync, :freshness],
        %{seconds_since_run: DateTime.diff(now, s.at)},
        %{label: label, outcome: s.outcome}
      )
    end)
  end

  # ── Public API ─────────────────────────────────────────

  @doc """
  Run `fun` under a fresh sync-reporter run named `label`.

  Returns whatever `fun` returns. On exception or `throw`, the
  summary line is still emitted (as `error`) and the original
  reason is re-raised so call-site rescues see it unchanged.
  """
  def with_run(label, fun) when is_binary(label) and is_function(fun, 0) do
    # Not re-entrant: counters live under a single process-dict key, so a
    # nested `with_run` on the same process would reset the outer run's
    # counters and the inner `after` would wipe them entirely. Guard
    # against accidental nesting by running the inner function plainly
    # (no fresh counters, no delete) and letting the outer run own the
    # summary — rather than silently corrupting it.
    if Process.get(@counters_key) do
      Logger.warning(
        "[#{colorize_label(label)}] Reporter.with_run/2 called re-entrantly; running without a nested summary"
      )

      fun.()
    else
      do_with_run(label, fun)
    end
  end

  defp do_with_run(label, fun) do
    started_at = System.monotonic_time()
    Process.put(@counters_key, fresh_counters())
    Process.put(@run_label_key, label)
    Logger.info("[#{colorize_label(label)}] starting…")

    try do
      result = fun.()
      log_summary(label, started_at, outcome(result))
      result
    rescue
      e ->
        log_summary(label, started_at, :error)
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        log_summary(label, started_at, :error)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.delete(@counters_key)
      Process.delete(@run_label_key)
    end
  end

  @doc """
  The label of the sync run active on this process, or `"unknown"` outside a run.

  Exists so code deep inside a pipeline can attribute a telemetry event to the sync
  that caused it without every intermediate function having to thread a label
  through — see `EftBuddy.Sync.Helpers.cleanup_safe?/3`, which is called from nine
  places and takes only row counts.
  """
  @spec current_label() :: String.t()
  def current_label, do: Process.get(@run_label_key, "unknown")

  @doc """
  Increment the warning counter for the active run without
  emitting a Logger line. Falls back to `Logger.warning/1`
  when called outside a run.

  Use for high-volume per-row warnings whose presence is more
  useful as a count (e.g. "skipped 12 item requirements") than
  one line per occurrence.
  """
  def silent_warn(message) do
    case Process.get(@counters_key) do
      nil ->
        Logger.warning(message)

      counters ->
        Process.put(@counters_key, %{counters | warnings: counters.warnings + 1})
    end

    :ok
  end

  @doc """
  Record that this run refused a destructive prune (see
  `EftBuddy.Sync.Helpers.cleanup_safe?/3`).

  A refusal is the single most important thing a sync can report and it used to be
  the least visible: the guard logged an error from whichever module was running, and
  **the run still recorded `outcome: :ok`**. So the app knowingly served a snapshot it
  had distrusted, `EftBuddyWeb.LoadState` saw a healthy feed, and `/health` answered
  200. Counting it here puts it in three places at once — the run's summary line, the
  `[:eft_buddy, :sync, :stop]` measurements, and the last-run record that
  `EftBuddy.Sync.Freshness` turns into a readiness verdict.
  """
  @spec count_refusal() :: :ok
  def count_refusal do
    case Process.get(@counters_key) do
      nil -> :ok
      counters -> Process.put(@counters_key, %{counters | refusals: counters.refusals + 1})
    end

    :ok
  end

  @doc """
  Wrap a sync-module label in ANSI color codes so it stands
  out from neighbouring lines in the console.

  Returns plain text in any context where ANSI is disabled
  (production logs, CI, redirected stdout, journald, etc.) so
  log shippers don't ingest `\\e[36m…` garbage.

  Public so other syncer-adjacent modules (`Bootstrap`) can
  match the same palette.

  Tolerant of a `:mode` suffix: per-mode runs label themselves
  `"TasksSync:regular"` / `"BartersSync:pve"` etc., which used to miss
  the exact-match lookup and print uncolored. We now key the color on
  the base label (the part before the first `:`), so the whole tag —
  suffix included — is colorized like its un-suffixed sibling.
  """
  def colorize_label(label) when is_binary(label) do
    if IO.ANSI.enabled?() do
      # `IO.ANSI.format/1` already appends a trailing reset, so
      # we don't need to include `:reset` ourselves — that would
      # produce a redundant `\e[0m\e[0m` pair.
      [label_color(label), label]
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()
    else
      label
    end
  end

  # Resolve a label (possibly `"Base:mode"`) to its ANSI color. Keys on
  # the base label so mode-suffixed runs share their family's color, and
  # falls back to the shared data-sync color for anything unmapped.
  defp label_color(label) do
    base = label |> String.split(":", parts: 2) |> hd()
    Map.get(@label_colors, base, @default_label_color)
  end

  # ── Error rendering ────────────────────────────────────

  @doc """
  Render a sync error reason as a compact, single-line summary.

  Sync failures travel as tagged tuples — `{:unexpected_response, status,
  body}`, `{:crash, message}`, `{:partial, ok, failures}`,
  `{:invalid_locale, path}`, … — and logging them with a raw `inspect/1`
  dumps multi-line payloads. The worst offender is the ~15-key Cloudflare
  `error 1102` body, which on its own buries every surrounding line and, in
  a `{:partial, …}` or list, repeats per entry.

  This collapses the shapes we actually emit into a single readable clause
  and truncates anything unrecognised, so every error log site can stay one
  tidy line. Keep the full term for forensics by pairing the call with a
  `Logger.debug(fn -> inspect(reason, pretty: true) end)` — dropped in prod,
  available in dev.

      iex> describe_error({:unexpected_response, 503,
      ...>   %{"title" => "Error 1102: Worker exceeded resource limits",
      ...>     "retryable" => false, "zone" => "api.tarkov.dev"}})
      "HTTP 503 from api.tarkov.dev — Error 1102: Worker exceeded resource limits (non-retryable)"
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:unexpected_response, status, %{} = body}) do
    detail =
      [body["title"] || body["error_name"], retryable_note(body)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    host = if is_binary(body["zone"]), do: " from #{body["zone"]}", else: ""

    case detail do
      "" -> "HTTP #{status}#{host}"
      _ -> "HTTP #{status}#{host} — #{detail}"
    end
  end

  def describe_error({:unexpected_response, status, _body}), do: "HTTP #{status}"

  def describe_error({:crash, message}) when is_binary(message), do: "crash — #{message}"

  # JSON-API fetch failures (see `EftBuddy.TarkovApi`): keep each to one
  # short, operator-readable line. The path identifies the failing
  # endpoint (e.g. `/pve/items_en`); the surrounding sync log line
  # already names the domain.
  def describe_error({:invalid_locale, path}),
    do: "missing or invalid translation document #{path}"

  def describe_error({:json_decode_failed, _}), do: "response body was not valid JSON"

  def describe_error({:unexpected_body, _}), do: "unexpected (non-JSON) response body"

  # A per-mode roll-up (e.g. Tasks: regular committed, pve failed). Name the
  # modes that succeeded and, for each that failed, recurse into its reason.
  def describe_error({:partial, successes, failures}) do
    ok_part =
      successes
      |> Enum.map(fn {mode, counts} -> "#{mode} ok#{task_count(counts)}" end)
      |> Enum.join(", ")

    fail_part =
      failures
      |> Enum.map(fn {mode, reason} -> "#{mode} failed (#{describe_error(reason)})" end)
      |> Enum.join("; ")

    [ok_part, fail_part] |> Enum.reject(&(&1 == "")) |> Enum.join("; ")
  end

  def describe_error(:already_running), do: "another sync is already running"

  # Unknown shape: still one line, but cap the length so a stray large term
  # can't reintroduce the wall-of-text we're trying to kill.
  def describe_error(other), do: truncate(inspect(other), 300)

  defp retryable_note(%{"retryable" => false}), do: "(non-retryable)"
  defp retryable_note(_), do: nil

  defp task_count(%{tasks: n}) when is_integer(n), do: " (#{n} tasks)"
  defp task_count(_), do: ""

  defp truncate(string, max) do
    if String.length(string) > max, do: String.slice(string, 0, max) <> "…", else: string
  end

  # ── Telemetry handler ──────────────────────────────────

  @doc false
  def handle_query_event(_event, measurements, metadata, _config) do
    case Process.get(@counters_key) do
      nil ->
        emit_default_log(measurements, metadata)

      counters ->
        Process.put(@counters_key, increment(counters, measurements, metadata))
    end

    :ok
  end

  # ── Counter helpers ────────────────────────────────────

  defp fresh_counters do
    blank_op = %{count: 0, rows: 0, time_ns: 0}

    %{
      ops: Map.new(@op_order, &{&1, blank_op}),
      warnings: 0,
      errors: 0,
      refusals: 0
    }
  end

  defp increment(counters, measurements, metadata) do
    op = classify(metadata[:query])

    # Skip pure transactional control statements — they're noise
    # for the operation breakdown.
    if op == :transaction do
      counters
    else
      rows = rows_from(metadata[:result])
      time_ns = Map.get(measurements, :total_time, 0)

      update_in(counters, [:ops, op], fn s ->
        %{
          count: s.count + 1,
          rows: s.rows + rows,
          time_ns: s.time_ns + time_ns
        }
      end)
      |> bump_errors_if_query_failed(metadata)
    end
  end

  defp bump_errors_if_query_failed(counters, %{result: {:error, _}}) do
    %{counters | errors: counters.errors + 1}
  end

  defp bump_errors_if_query_failed(counters, _), do: counters

  defp rows_from({:ok, %{num_rows: n}}) when is_integer(n), do: n
  defp rows_from(_), do: 0

  defp classify(query) when is_binary(query) do
    case String.trim_leading(query) do
      "SELECT" <> _ -> :select
      "INSERT" <> _ -> :insert
      "UPDATE" <> _ -> :update
      "DELETE" <> _ -> :delete
      "WITH" <> _ -> :select
      "BEGIN" <> _ -> :transaction
      "COMMIT" <> _ -> :transaction
      "ROLLBACK" <> _ -> :transaction
      "SAVEPOINT" <> _ -> :transaction
      "RELEASE" <> _ -> :transaction
      _ -> :other
    end
  end

  defp classify(_), do: :other

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, _}), do: :error
  defp outcome(:ok), do: :ok

  # A run that DECLINED to do its work — `sync_barters/1` returning
  # `{:skip, "no resolvable barters…"}` because the traders it needs are not in
  # the database yet. It is not an error (nothing went wrong) and it is
  # emphatically not a success (nothing was written), and it used to fall
  # through to `:done` below, where `EftBuddy.Sync.Freshness` — which only ever
  # looked for `:error` — read it as healthy. A feed that skipped every single
  # run therefore reported green forever.
  #
  # That is survivable while every skippable step runs inside one sequential
  # pipeline that guarantees its own ordering. Once the feeds have independent
  # timers it is not: a syncer whose dependency has not run yet skips, and
  # nothing says so.
  defp outcome({:skip, _}), do: :skipped
  defp outcome(_), do: :done

  # ── Logging ────────────────────────────────────────────

  defp log_summary(label, started_at, outcome) do
    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    counters = Process.get(@counters_key) || fresh_counters()

    queries_part =
      counters.ops
      |> Enum.filter(fn {_op, s} -> s.count > 0 end)
      |> Enum.sort_by(fn {op, _} -> Enum.find_index(@op_order, &(&1 == op)) end)
      |> Enum.map(&format_op/1)
      |> case do
        [] -> "no queries"
        parts -> Enum.join(parts, ", ")
      end

    # `refusals` is only rendered when non-zero: it should stand out as an event, not
    # blend into a field that reads `0` on every healthy line.
    refusals_part =
      if counters.refusals > 0, do: " REFUSED-PRUNES=#{counters.refusals}", else: ""

    Logger.info(
      "[#{colorize_label(label)}] #{outcome} in #{fmt_time(elapsed_ms)} — " <>
        "#{queries_part} — warnings=#{counters.warnings} errors=#{counters.errors}" <>
        refusals_part
    )

    record_status(label, outcome, elapsed_ms, counters)
  end

  # Persist the last-run status and emit a telemetry event so operators
  # have a dashboardable signal for sync health (success/failure/duration)
  # instead of having to scrape logs.
  defp record_status(label, outcome, elapsed_ms, counters) do
    :telemetry.execute(
      [:eft_buddy, :sync, :stop],
      %{
        duration_ms: elapsed_ms,
        warnings: counters.warnings,
        errors: counters.errors,
        refusals: counters.refusals
      },
      %{label: label, outcome: outcome}
    )

    if :ets.whereis(@status_table) != :undefined do
      now = DateTime.utc_now()

      # Read-modify-write, which is safe here because each label has exactly one
      # writer: every syncer is a `{:global, __MODULE__}` singleton and holds its
      # lock for the duration of the run. A lost update would at worst delay a
      # staleness verdict by one cycle.
      prev =
        case :ets.lookup(@status_table, label) do
          [{^label, s}] -> s
          [] -> %{}
        end

      :ets.insert(
        @status_table,
        {label,
         %{
           outcome: outcome,
           at: now,
           duration_ms: elapsed_ms,
           # Carried in the record, not just the log line, so
           # `EftBuddy.Sync.Freshness` can fail readiness on it. A run that refused a
           # prune completed "successfully" while knowingly serving a snapshot it
           # distrusted — `outcome` alone cannot express that.
           refusals: counters.refusals,
           # `at` is when this feed last RAN; this is when it last WORKED, and the
           # two diverge exactly when it matters. Freshness ages a family on this,
           # so a feed that runs on schedule and skips (or errors) every time now
           # goes stale on its budget instead of looking permanently current — its
           # `at` was being refreshed by runs that wrote nothing.
           last_ok_at: if(outcome == :ok, do: now, else: Map.get(prev, :last_ok_at)),
           # Not read by anything today. It is here because "skipped once on a cold
           # start" and "has skipped forty times in a row" are the same record
           # otherwise, and the second is the shape worth seeing on a dashboard.
           consecutive_skips:
             if(outcome == :skipped, do: Map.get(prev, :consecutive_skips, 0) + 1, else: 0)
         }}
      )
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp format_op({op, %{count: count, rows: rows}}) do
    op_name = op |> Atom.to_string() |> String.upcase() |> colorize_op(op)

    rows_str =
      cond do
        op in [:insert, :delete] -> " (#{rows} rows)"
        op == :update and rows > 0 -> " (#{rows} rows)"
        true -> ""
      end

    "#{op_name} #{count}#{rows_str}"
  end

  # Apply the op-keyword color when ANSI is enabled. Mirrors
  # `colorize_label/1` but takes the atom op directly so the
  # caller can pass the already-uppercased text and we wrap it
  # without re-deriving.
  defp colorize_op(text, op) do
    if IO.ANSI.enabled?() and Map.has_key?(@op_colors, op) do
      [@op_colors[op], text]
      |> IO.ANSI.format()
      |> IO.iodata_to_binary()
    else
      text
    end
  end

  # Threshold rationale: under 1s, ms is precise and short.
  # Over 1s, switch to seconds with 2 decimals (e.g. 12.42s).
  # No fallback clause for non-integers: every call site passes
  # a `System.convert_time_unit/3` result, which is statically
  # `integer()`, and Elixir 1.18's flow type checker correctly
  # flags any `_` catch-all here as unreachable.
  defp fmt_time(ms) when is_integer(ms) and ms >= 1_000 do
    "#{:erlang.float_to_binary(ms / 1000, decimals: 2)}s"
  end

  defp fmt_time(ms) when is_integer(ms), do: "#{ms}ms"

  # Fallback "Ecto-style" log when we receive a query telemetry
  # event outside of a sync run. Keeps dev request-time query
  # visibility working after we set `log: false` on the Repo.
  # In prod, level is :info so this debug call is dropped.
  defp emit_default_log(measurements, metadata) do
    Logger.debug(fn ->
      total_us =
        System.convert_time_unit(measurements[:total_time] || 0, :native, :microsecond)

      query_us =
        System.convert_time_unit(measurements[:query_time] || 0, :native, :microsecond)

      decode_us =
        System.convert_time_unit(measurements[:decode_time] || 0, :native, :microsecond)

      queue_us =
        System.convert_time_unit(measurements[:queue_time] || 0, :native, :microsecond)

      ok_or_error =
        case metadata[:result] do
          {:ok, _} -> "OK"
          _ -> "ERROR"
        end

      [
        "QUERY ",
        ok_or_error,
        " source=",
        to_string(metadata[:source] || "-"),
        " db=",
        :erlang.float_to_binary(total_us / 1000, decimals: 1),
        "ms queue=",
        :erlang.float_to_binary(queue_us / 1000, decimals: 1),
        "ms query=",
        :erlang.float_to_binary(query_us / 1000, decimals: 1),
        "ms decode=",
        :erlang.float_to_binary(decode_us / 1000, decimals: 1),
        "ms\n",
        to_string(metadata[:query] || ""),
        " ",
        inspect(metadata[:params] || [])
      ]
    end)
  end
end
