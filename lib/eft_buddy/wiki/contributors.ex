defmodule EftBuddy.Wiki.Contributors do
  @moduledoc """
  Fetches the contributor roster for a batch of wiki pages.

  The prose we render from the wiki is CC BY-NC-SA, where naming the
  creators is a condition of the licence. `prop=contributors` gives us the
  people who actually wrote a given page, so a guide can credit its own
  eleven authors instead of a generic "wiki contributors" line.

  Shared by all three wiki scrapers (`EftBuddy.Wiki.Sync`,
  `EftBuddy.Chapters.Sync`, `EftBuddy.Events.Sync`), which each fetch the
  roster for their page set up front and merge it into the manifest they
  already write.

  ## Batching

  `pclimit` is shared across every title in a request, not applied per
  title. Pages here carry 11–30 contributors, so a 50-title batch would
  blow past the cap and paginate; we use a smaller batch and follow the
  `continue` token, merging each continuation into the accumulator.

  ## Anonymous edits

  The API reports anonymous contributors as a bare count with no identity, so
  they could only ever be surfaced as a number, never as a name.

  Nothing renders that number today — the credit popup was trimmed to the
  named contributors it can actually link to. It is still captured into the
  manifest rather than dropped, because it costs nothing (the API returns it
  alongside the names) and surfacing it later would otherwise need a full
  re-sync. The read-model projections deliberately do not expose it.
  """

  alias EftBuddy.Wiki.DumpScript

  # Deliberately well under the 500-contributor `pclimit`: ~20 titles at
  # ~25 contributors each stays inside one response most of the time,
  # while still cutting request count by 20x versus one call per page.
  @batch 20

  # Guard against a pathological continuation loop. Far above the handful
  # of round-trips a batch this size can legitimately need.
  @max_pages 50

  @typedoc "One page's roster: named contributors plus the anonymous count."
  @type roster :: %{names: [String.t()], anon: non_neg_integer()}

  @doc """
  Fetch rosters for `titles`, returning `%{title => roster | :unavailable}`.

  A title absent from the result does not exist on the wiki. `:unavailable`
  means its batch failed, so its credits are unknown rather than empty: a
  scraper renders the generic credit line for it, and `EftBuddy.Wiki.Sync`
  does not mark the page current, so the roster is fetched again next run.
  """
  @spec fetch([String.t()], keyword()) :: %{String.t() => roster() | :unavailable}
  def fetch(titles, http_opts) when is_list(titles) and is_list(http_opts) do
    titles
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.chunk_every(@batch)
    |> Enum.reduce(%{}, fn batch, acc ->
      case fetch_batch(batch, %{}, %{}, http_opts, 1) do
        {:ok, rosters} ->
          rosters
          |> Map.new(fn {title, roster} ->
            {title, %{roster | names: roster.names |> Enum.uniq() |> Enum.sort()}}
          end)
          |> Map.merge(acc)

        :error ->
          Map.merge(acc, Map.new(batch, &{&1, :unavailable}))
      end
    end)
  end

  @doc """
  Merge a roster into a scraper manifest, before it is JSON round-tripped
  into the `content` column.

  A `nil` or `:unavailable` roster still writes the keys, empty, and the UI
  renders the generic credit line for both.
  """
  @spec merge(map(), roster() | :unavailable | nil) :: map()
  def merge(manifest, roster) when is_map(manifest) and roster in [nil, :unavailable] do
    Map.merge(manifest, %{contributors: [], anon_contributors: 0})
  end

  def merge(manifest, %{names: names, anon: anon}) when is_map(manifest) do
    Map.merge(manifest, %{contributors: names, anon_contributors: anon})
  end

  # ── Internals ──────────────────────────────────────────────────────

  # `{:ok, rosters}` or `:error`. A batch whose continuation fails part way is
  # an error as a whole: its rosters would be missing names, and a partial
  # credit list is not one we can pass off as complete.
  defp fetch_batch(_batch, _continue, _acc, _http_opts, page) when page > @max_pages do
    EftBuddy.Sync.Reporter.silent_warn("[Contributors] continuation limit hit; batch dropped")
    :error
  end

  defp fetch_batch(batch, continue, acc, http_opts, page) do
    params =
      Map.merge(
        %{
          "action" => "query",
          "prop" => "contributors",
          "titles" => Enum.join(batch, "|"),
          "pclimit" => "max",
          "format" => "json",
          "formatversion" => "2",
          "redirects" => "1"
        },
        continue
      )

    case DumpScript.api_get(params, http_opts) do
      {:ok, body} ->
        acc = collect(body, acc)

        case body["continue"] do
          nil -> {:ok, acc}
          next -> fetch_batch(batch, stringify(next), acc, http_opts, page + 1)
        end

      {:error, reason} ->
        # Counted on the run's `warnings=` rather than logged per batch.
        EftBuddy.Sync.Reporter.silent_warn("[Contributors] batch failed: #{inspect(reason)}")
        :error
    end
  end

  defp collect(body, acc) do
    # MediaWiki may normalise or redirect a requested title, so map the
    # returned title back to what the caller asked for -- otherwise the
    # lookup by `wiki_title` at write time silently misses.
    original_for = DumpScript.requested_title_resolver(body)

    (get_in(body, ["query", "pages"]) || [])
    |> Enum.reduce(acc, fn page, inner ->
      case page do
        %{"missing" => true} ->
          inner

        %{"title" => title} ->
          roster = %{
            names:
              (page["contributors"] || [])
              |> Enum.map(& &1["name"])
              |> Enum.reject(&(is_nil(&1) or &1 == "")),
            anon: page["anoncontributors"] || 0
          }

          Map.update(inner, original_for.(title), roster, &merge_roster(&1, roster))

        _ ->
          inner
      end
    end)
  end

  # Continuations carry the named contributors in slices; the anonymous
  # count is reported whole each time, so take the larger rather than
  # summing it.
  defp merge_roster(a, b) do
    %{names: a.names ++ b.names, anon: max(a.anon, b.anon)}
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
