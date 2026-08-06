defmodule EftBuddy.Sync.Helpers do
  @moduledoc """
  Small stateless helpers shared by the Items / Tasks / Hideout sync
  pipelines: timestamp generation, numeric coercion of GraphQL values,
  slug derivation, and the destructive-cleanup safety guard. Imported
  by each `*.Sync` module.
  """

  @doc """
  Decide whether a stale-row cleanup is safe to perform, given the live
  row `current` count and the `snapshot` size from the latest upstream
  fetch.

  ## Why

  Every sync prunes rows whose external id is absent from the latest API
  snapshot. tarkov.dev (and the Fandom wiki) can return a *truncated but
  HTTP-200* payload — a regional cache miss, an upstream timeout that
  still 200s with partial `data`, or a schema drift that drops a slice of
  a list. Acting on such a snapshot would delete the missing rows and,
  via the `on_delete: :delete_all` FKs, cascade into hideout requirements,
  task rewards, barters and crafts. That is the single most destructive
  failure mode in the app.

  This guard refuses the delete when the snapshot retains fewer than
  `ratio` (default 90%, overridable via the `:sync_cleanup_min_keep_ratio`
  app env) of the rows we already have. A healthy snapshot is always
  roughly the same size as (or larger than) the current table, so the
  guard never trips in normal operation; a partial snapshot is left to
  heal on the next tick rather than wiping good data.

  ## Why 90% and not 50%

  It was 50%, which meant a snapshot carrying exactly half the catalogue
  was accepted and the other half deleted — cascading through 57
  `on_delete: :delete_all` FKs while the run still reported `outcome: :ok`
  and `/health/sync` stayed green.

  50% is the wrong shape of number for this. These catalogues grow
  monotonically; there is no legitimate reason for one to shrink by more
  than a few percent between runs, so any threshold generous enough to
  admit a *halved* table is describing a failure, not a floor. The cost of
  being wrong is asymmetric: refusing a legitimate prune leaves stale rows
  that the next tick removes, while accepting a truncated one destroys data
  no sync rebuilds.

  It matters more than it used to. These syncs now run unattended on a
  daily timer rather than only when someone deploys, so nobody is watching
  when the guard makes its decision.

  Returns `:ok` to proceed with the delete, or `{:skip, reason}` to refuse.
  A cold start (`current == 0`) always returns `:ok` so the first
  population is never blocked.
  """
  @spec cleanup_safe?(non_neg_integer(), non_neg_integer(), float()) ::
          :ok | {:skip, String.t()}
  def cleanup_safe?(current, snapshot, ratio \\ cleanup_min_keep_ratio())
      when is_integer(current) and is_integer(snapshot) and current >= 0 and snapshot >= 0 do
    cond do
      current == 0 ->
        :ok

      snapshot >= current * ratio ->
        :ok

      true ->
        # A refused prune is this guard catching a truncated upstream response —
        # the single most destructive failure mode in the app announcing itself.
        # Until this event existed, the announcement was a `Logger.error` in
        # whichever sync module happened to be running, inside a log stream nobody
        # watches, and the RUN ITSELF still reported `ok`. So the one condition an
        # operator most needs to know about was the one thing the instrumentation
        # could not tell them.
        #
        # `EftBuddy.Sync.Reporter.current_label/0` supplies the attribution: this
        # function is called from nine places and receives only row counts, so
        # threading a label through every caller would be a far larger change than
        # reading the active run off the process dictionary.
        :telemetry.execute(
          [:eft_buddy, :sync, :cleanup_refused],
          %{current_count: current, snapshot_count: snapshot},
          %{label: EftBuddy.Sync.Reporter.current_label(), ratio: ratio}
        )

        # And record it against the run itself, so it reaches the summary line and
        # the last-run record that `/health/sync` reads. The telemetry event above
        # only reaches an attached reporter; this is what makes the refusal survive
        # into the readiness verdict.
        EftBuddy.Sync.Reporter.count_refusal()

        {:skip,
         "snapshot=#{snapshot} would keep < #{round(ratio * 100)}% of the " <>
           "#{current} existing rows — treating as a partial/corrupt upstream response"}
    end
  end

  @doc """
  Decide whether a price snapshot is safe to write.

  `cleanup_safe?/3` guards DELETES. This guards an UPSERT, because on the price
  path an upsert is destructive in exactly the same way and `cleanup_safe?/3`
  cannot see it. `refresh_item_prices_flea/3` writes with
  `on_conflict: {:replace, [:last_low_price, …]}`, so a nil `lastLowPrice` in the
  response goes straight over a live price as a NULL. An upstream document that
  still lists all ~5,200 items with its price fields stripped therefore nulls the
  whole catalogue in one pass — **with no change in row count at all** for a size
  guard to notice.

  The signal is not "a nil price". Items that were never listed on the flea market
  legitimately have none, and the catalogue always carries plenty. The signal is a
  mass TRANSITION from priced to unpriced, so the comparison is between how many
  rows carry a price now and how many the incoming snapshot carries.

  A cold start (`current == 0`) always returns `:ok`, exactly as `cleanup_safe?/3`
  does — the first population must never be blocked.

  Note that an EMPTY document trips this rather than silently writing nothing,
  which is a deliberate change of behaviour: a price feed returning zero priced
  items is a real upstream failure and should reach `/health/sync` instead of
  vanishing into a run that reports `ok` with `upserted: 0`.

  Returns `:ok` to proceed, or `{:skip, reason}` to refuse.
  """
  @spec prices_safe?(non_neg_integer(), non_neg_integer(), float()) ::
          :ok | {:skip, String.t()}
  def prices_safe?(current, incoming, ratio \\ cleanup_min_keep_ratio())
      when is_integer(current) and is_integer(incoming) and current >= 0 and incoming >= 0 do
    cond do
      current == 0 ->
        :ok

      incoming >= current * ratio ->
        :ok

      true ->
        # Reuses `:cleanup_refused` rather than minting a `:prices_refused` event.
        # The whole surfacing chain downstream of this — `count_refusal/0` →
        # `refusals` → `REFUSED-PRUNES=n` on the summary line → `:guard_tripped` in
        # `EftBuddy.Sync.Freshness` → 503 from `/health/sync` — is keyed on the
        # counter, not the event name, and a second event would need new metric
        # declarations and a new path through `Reporter` to express the same fact.
        # `guard:` distinguishes the two in metadata for anyone charting them.
        :telemetry.execute(
          [:eft_buddy, :sync, :cleanup_refused],
          %{current_count: current, snapshot_count: incoming},
          %{label: EftBuddy.Sync.Reporter.current_label(), ratio: ratio, guard: :prices}
        )

        EftBuddy.Sync.Reporter.count_refusal()

        {:skip,
         "snapshot carries #{incoming} priced items against #{current} currently " <>
           "priced (< #{round(ratio * 100)}%) — treating as a null-stripped upstream response"}
    end
  end

  @doc false
  # One ratio, shared by both guards. Prices move constantly but the COUNT of
  # priced items does not — that set is the flea-eligible catalogue, and it is as
  # monotone as the catalogue itself. A second knob would be a second number to
  # keep in step for no demonstrated need.
  def cleanup_min_keep_ratio do
    Application.get_env(:eft_buddy, :sync_cleanup_min_keep_ratio, 0.9)
  end

  @doc """
  Second-precision UTC `NaiveDateTime` for the `inserted_at` /
  `updated_at` values we set by hand in `insert_all` / `update_all`
  (those bypass the schema's autogenerated timestamps).
  """
  def now_naive, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  @doc """
  Coerce a Tarkov.dev numeric field to a float. The API types several
  fields as `Float` but returns whole numbers as integers, which Ecto's
  `:float` type rejects in `insert_all`. Anything non-numeric (the API
  has occasionally returned strings / nulls) becomes `nil` so a single
  odd value can't crash a whole sync run.
  """
  def to_float(nil), do: nil
  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value * 1.0
  def to_float(_), do: nil

  @doc """
  Derive a normalized slug — lowercase, non-alphanumerics collapsed to
  dashes, leading/trailing dashes trimmed — for names the API doesn't
  give a `normalizedName` for (skills, quest items). `nil` passes
  through unchanged.
  """
  def slugify(nil), do: nil

  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # HTTP statuses Req's `:transient` policy treats as retryable.
  @transient_statuses [408, 429, 500, 502, 503, 504]

  @doc """
  Retry predicate for the tarkov.dev `Req` calls. Pass it as
  `retry: &EftBuddy.Sync.Helpers.retry_transient?/2`.

  It mirrors Req's built-in `retry: :transient` — retry on a transient
  HTTP status (#{inspect(@transient_statuses)}) for any method, plus the
  transient transport/HTTP-2 errors — with **one** exception: it refuses
  to retry a response the upstream has explicitly flagged as non-retryable.

  ## Why

  tarkov.dev's GraphQL endpoint sits behind Cloudflare. When its Worker
  exceeds its CPU/memory budget Cloudflare returns **HTTP 503 with an
  "error 1102" body** that carries `"retryable" => false` (and
  `"cloudflare_error" => true`). Retrying is futile — the same request
  re-hits the same resource limit — and the plain `:transient` policy would
  otherwise burn the whole retry budget (≈1s+2s+4s of backoff plus three
  more dead requests, ~7s+) before the failure ever surfaces. Treating such
  a response as terminal lets the caller fail fast. The fix the body asks
  for is on the *site owner's* side, not ours.

  A bare 503 with no such flag (e.g. the Fandom wiki's rate-limit 503, which
  ships a `Retry-After`) is still retried, exactly as before.

  ## Implementation note: the body isn't decoded yet

  Req runs `retry` as the **first** response step — *before* `decompress_body`
  and `decode_body`. So at this point `response.body` is the raw, still-
  compressed payload, **not** the decoded map. We therefore decode it here
  ourselves before reading the flags. Req only advertises `gzip` in
  `accept-encoding` (the optional `brotli`/`ezstd` deps aren't pulled in), so
  the body is either identity JSON or gzip'd JSON; we try both. Anything we
  can't confidently parse is treated as retryable — the safe default,
  identical to plain `:transient`.
  """
  @spec retry_transient?(Req.Request.t(), Req.Response.t() | Exception.t()) :: boolean()
  def retry_transient?(request, response_or_exception)

  def retry_transient?(_request, %Req.Response{status: status} = response) do
    status in @transient_statuses and not non_retryable?(response.body)
  end

  def retry_transient?(_request, %Req.TransportError{reason: reason})
      when reason in [:timeout, :econnrefused, :closed],
      do: true

  def retry_transient?(_request, %Req.HTTPError{protocol: :http2, reason: :unprocessed}), do: true

  def retry_transient?(_request, _other), do: false

  # Cloudflare's 1xxx Worker errors (notably 1102 "Worker exceeded resource
  # limits") and any body that self-reports `retryable: false` are terminal:
  # an identical retry would deterministically fail the same way.
  defp non_retryable?(body) do
    case decode_body(body) do
      %{} = map ->
        flag(map, "retryable", :retryable) == false or
          flag(map, "cloudflare_error", :cloudflare_error) == true

      _ ->
        false
    end
  end

  # Best-effort decode of the (pre-decompress) response body to a map.
  # Already a map (a unit test, or a future Req that decodes earlier) →
  # use as-is. A binary is either identity JSON or gzip'd JSON: try a
  # straight decode first, then gunzip-then-decode. Unparseable (e.g. a
  # brotli/zstd body we can't read, or an HTML error page) → nil, which
  # the caller treats as "retry".
  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> body |> gunzip() |> decode_json()
    end
  end

  defp decode_body(_), do: nil

  defp gunzip(body) do
    {:ok, :zlib.gunzip(body)}
  rescue
    _ -> :error
  end

  defp decode_json({:ok, json}) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> nil
    end
  end

  defp decode_json(:error), do: nil

  # Read a flag that may be string- or atom-keyed (decoded JSON is
  # string-keyed; accept atoms too so a quirk can't defeat the check).
  defp flag(body, string_key, atom_key) do
    case Map.fetch(body, string_key) do
      {:ok, value} -> value
      :error -> Map.get(body, atom_key)
    end
  end
end
