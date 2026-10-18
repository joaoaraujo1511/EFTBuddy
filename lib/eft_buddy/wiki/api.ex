defmodule EftBuddy.Wiki.Api do
  @moduledoc """
  The MediaWiki requests the three Fandom scrapers share: a page's section list,
  one section's (or a whole page's) wikitext, image info, revision ids and a
  category's members.

  Each scraper used to carry its own copy of these, and the copies had drifted
  (audit L28): only one checked the API's `error` body, and they disagreed on
  whether a failed section was an error or an empty string. Every function here
  answers with an explicit `{:ok, _} | {:error, _}`, or for the batched lookups a
  count of failed batches, so the caller decides what a failure costs instead of
  a swallowed `""` deciding for it.

  The transport, throttle and retries stay in `EftBuddy.Wiki.DumpScript.api_get/2`.
  """

  import Ecto.Query

  require Logger

  alias EftBuddy.Repo
  alias EftBuddy.Sync.Helpers
  alias EftBuddy.Wiki.{DumpScript, FileLicense}

  @url "https://escapefromtarkov.fandom.com/api.php"

  # MediaWiki caps `titles` at 50 per query for anonymous callers.
  @batch 50

  @doc "Options every scraper passes to `DumpScript.api_get/2` and its helpers."
  @spec http_opts() :: keyword()
  def http_opts, do: [url: @url, user_agent: DumpScript.user_agent()]

  @doc """
  A page's own section list, as `%{index, heading, level, fromtitle}` maps.
  `fromtitle` names the template a transcluded section comes from.
  """
  @spec section_list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def section_list(title) do
    with {:ok, body} <- mw_parse(%{"page" => title, "prop" => "sections"}) do
      {:ok,
       body
       |> get_in(["parse", "sections"])
       |> List.wrap()
       |> Enum.map(fn s ->
         %{index: s["index"], heading: s["line"], level: s["level"], fromtitle: s["fromtitle"]}
       end)}
    end
  end

  @doc "One section's raw wikitext."
  @spec section_wikitext(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def section_wikitext(title, index) do
    with {:ok, body} <- mw_parse(%{"page" => title, "prop" => "wikitext", "section" => index}) do
      {:ok, get_in(body, ["parse", "wikitext"]) || ""}
    end
  end

  @doc "A whole page's raw wikitext."
  @spec page_wikitext(String.t()) :: {:ok, String.t()} | {:error, term()}
  def page_wikitext(title) do
    with {:ok, body} <- mw_parse(%{"page" => title, "prop" => "wikitext"}) do
      {:ok, get_in(body, ["parse", "wikitext"]) || ""}
    end
  end

  @doc """
  Image info for `file_titles` (each `"File:Name.ext"`), keyed by the title as
  requested, plus how many batches failed. A missing file is simply absent.
  """
  @spec imageinfo([String.t()], String.t()) :: {%{String.t() => map()}, non_neg_integer()}
  def imageinfo(file_titles, iiprop) do
    batched(
      file_titles,
      fn batch ->
        mw_query(%{"titles" => Enum.join(batch, "|"), "prop" => "imageinfo", "iiprop" => iiprop})
      end,
      fn
        %{"missing" => true} -> nil
        %{"imageinfo" => [iinfo | _]} -> iinfo
        _ -> nil
      end
    )
  end

  @doc """
  Each page's current revision id, keyed by the title as requested, plus how
  many batches failed. Ids only: the cheapest thing the API can answer with.
  """
  @spec revision_ids([String.t()]) :: {%{String.t() => integer()}, non_neg_integer()}
  def revision_ids(titles) do
    batched(
      titles,
      fn batch ->
        mw_query(%{"titles" => Enum.join(batch, "|"), "prop" => "revisions", "rvprop" => "ids"})
      end,
      fn
        %{"revisions" => [%{"revid" => revid} | _]} when is_integer(revid) -> revid
        _ -> nil
      end
    )
  end

  @doc """
  Every page in `category`, sorted and de-duplicated, or an error.

  All or nothing. It used to return whatever it had collected when a
  continuation request failed, and `Category:Quests` spans two pages: a failed
  second page returned the first 500 titles as if they were the whole category,
  and the prune that follows deleted every quest after "Night of The Cult"
  (audit H12).
  """
  @spec category_members(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def category_members(category), do: category_members(category, nil, MapSet.new())

  defp category_members(category, cmcontinue, acc) do
    params =
      %{
        "list" => "categorymembers",
        "cmtitle" => category,
        "cmlimit" => "500",
        "cmtype" => "page"
      }
      |> then(&if(cmcontinue, do: Map.put(&1, "cmcontinue", cmcontinue), else: &1))

    with {:ok, body} <- mw_query(params) do
      acc =
        body
        |> get_in(["query", "categorymembers"])
        |> List.wrap()
        |> Enum.reduce(acc, fn %{"title" => title}, set -> MapSet.put(set, title) end)

      case get_in(body, ["continue", "cmcontinue"]) do
        nil -> {:ok, acc |> MapSet.to_list() |> Enum.sort()}
        next -> category_members(category, next, acc)
      end
    end
  end

  @doc """
  Image info plus each file's own licence (`"license"`, nil when it declares
  none), keyed by the requested `"File:"` title, and how many batches of either
  lookup failed.
  """
  @spec images_with_licenses([String.t()], String.t()) ::
          {%{String.t() => map()}, non_neg_integer()}
  def images_with_licenses(file_titles, iiprop) do
    {info, info_failed} = imageinfo(file_titles, iiprop)
    {licenses, license_failed} = FileLicense.fetch(Map.keys(info), http_opts())

    {Map.new(info, fn {title, iinfo} -> {title, Map.put(iinfo, "license", licenses[title])} end),
     info_failed + license_failed}
  end

  # A scrape run is a failure once more than this share of the pages it
  # attempted failed, or all of them did.
  @max_failed_share 0.1

  @doc """
  The result a scrape run reports, from how many pages it attempted and how many
  of those failed.

  All three scrapes used to report `{:ok, _}` once enumeration worked, however
  many pages failed, so `/health/sync` stayed green over a summary reading
  `failed: 210` (audit H14). A run where more than 10% of its pages failed is now
  `{:error, {:pages_failed, failed, attempted, summary}}`: it gets the
  scheduler's one quick retry and counts toward the two-failures readiness rule.
  Below that it is `{:ok, summary}`, and the failed pages are fetched again next
  run.
  """
  @spec scrape_result(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:pages_failed, pos_integer(), pos_integer(), map()}}
  def scrape_result(summary, attempted, failed) do
    if attempted > 0 and failed > attempted * @max_failed_share do
      {:error, {:pages_failed, failed, attempted, summary}}
    else
      {:ok, summary}
    end
  end

  @doc """
  Delete every row of `schema` whose `normalized_name` is not in `keep`, unless
  that would remove an implausible share of the table.

  The guard measures overlap, how many existing rows `keep` still names, not raw
  sizes or `updated_at`: an unchanged wiki page is skipped rather than rewritten,
  so its timestamp says nothing about whether it was seen (the lesson of audit
  H1). Enumeration is already all or nothing; this is the second line, for a
  category or page that comes back structurally smaller. Returns the number of
  rows deleted (0 when refused, which `cleanup_safe?/3` reports itself).
  """
  @spec prune(module(), [String.t()]) :: non_neg_integer()
  def prune(_schema, []), do: 0

  def prune(schema, keep) do
    current = Repo.aggregate(schema, :count)
    kept = Repo.aggregate(from(r in schema, where: r.normalized_name in ^keep), :count)

    case Helpers.cleanup_safe?(current, kept) do
      :ok ->
        {deleted, _} = Repo.delete_all(from(r in schema, where: r.normalized_name not in ^keep))
        deleted

      {:skip, reason} ->
        Logger.error(
          "[#{EftBuddy.Sync.Reporter.current_label()}] Refusing stale wiki prune: #{reason}."
        )

        0
    end
  end

  # ── Internals ──────────────────────────────────────────────────────

  # `mw_` (MediaWiki) rather than `query`/`parse`: Sobelow reads any call to a
  # function named `query` as a possible raw SQL query.
  defp mw_parse(params) do
    DumpScript.api_get(
      Map.merge(%{"action" => "parse", "format" => "json", "formatversion" => "2"}, params),
      http_opts()
    )
  end

  defp mw_query(params) do
    DumpScript.api_get(
      Map.merge(
        %{"action" => "query", "format" => "json", "formatversion" => "2", "redirects" => "1"},
        params
      ),
      http_opts()
    )
  end

  # Run `request` per batch of 50 titles and collect `extract.(page)` for each
  # page, keyed by the title the caller asked for (MediaWiki normalises and
  # follows redirects, so the returned title can differ).
  defp batched(titles, request, extract) do
    titles
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.chunk_every(@batch)
    |> Enum.reduce({%{}, 0}, fn batch, {acc, failed} ->
      case request.(batch) do
        {:ok, body} ->
          original_for = DumpScript.requested_title_resolver(body)

          found =
            for %{"title" => title} = page <- List.wrap(get_in(body, ["query", "pages"])),
                value = extract.(page),
                not is_nil(value),
                into: %{},
                do: {original_for.(title), value}

          {Map.merge(acc, found), failed}

        {:error, _reason} ->
          {acc, failed + 1}
      end
    end)
  end
end
