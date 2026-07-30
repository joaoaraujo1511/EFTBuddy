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

  require Logger

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
  Fetch rosters for `titles`, returning `%{title => roster}`.

  Titles absent from the result either don't exist or failed to fetch; the
  caller treats a missing entry as "no credits captured" and renders the
  generic credit line rather than failing.
  """
  @spec fetch([String.t()], keyword()) :: %{String.t() => roster()}
  def fetch(titles, http_opts) when is_list(titles) and is_list(http_opts) do
    titles
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.chunk_every(@batch)
    |> Enum.reduce(%{}, fn batch, acc ->
      batch
      |> fetch_batch(%{}, %{}, http_opts, 1)
      |> Map.merge(acc, fn _title, a, b -> merge_roster(a, b) end)
    end)
    |> Map.new(fn {title, roster} ->
      {title, %{roster | names: roster.names |> Enum.uniq() |> Enum.sort()}}
    end)
  end

  @doc """
  Merge a roster into a scraper manifest, before it is JSON round-tripped
  into the `content` column.

  A `nil` roster still writes the keys, so a page whose fetch failed is
  distinguishable from one that predates this feature only by the sync
  timestamp — and the UI treats both the same way.
  """
  @spec merge(map(), roster() | nil) :: map()
  def merge(manifest, nil) when is_map(manifest) do
    Map.merge(manifest, %{contributors: [], anon_contributors: 0})
  end

  def merge(manifest, %{names: names, anon: anon}) when is_map(manifest) do
    Map.merge(manifest, %{contributors: names, anon_contributors: anon})
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp fetch_batch(_batch, _continue, acc, _http_opts, page) when page > @max_pages do
    Logger.warning("[Contributors] continuation limit hit; roster may be partial")
    acc
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
          nil -> acc
          next -> fetch_batch(batch, stringify(next), acc, http_opts, page + 1)
        end

      {:error, reason} ->
        # One failed batch must not sink the whole scrape: the pages in it
        # simply keep the credit line they already had.
        Logger.warning("[Contributors] batch failed: #{inspect(reason)}")
        acc
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
