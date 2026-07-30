defmodule EftBuddy.Wiki.FileLicense do
  @moduledoc """
  Reads the licence a wiki file page declares for itself.

  Most images on the wiki are Battlestate's own material and are out of
  scope for crediting. A small number are original work by a contributor —
  hand-drawn maps, mostly — and those carry an explicit `{{Copyright ...}}`
  template on their file page. Those are the ones that genuinely need an
  attribution, and they are the only ones this surfaces.

  ## Why a wikitext pass

  `imageinfo`'s `extmetadata` carries no licence fields on this wiki (only
  `DateTime` and `ObjectName`), so the CommonsMetadata route is unavailable.
  The declaration only exists in the file page's wikitext, which means a
  second batched request per file set.

  ## Scale

  Of the wiki's ~16,000 files, roughly 450 declare anything at all, and the
  overwhelming majority of those declare game material. Twelve files carry a
  licence we would credit. So the common result here is `nil`, and callers
  must treat `nil` as "say nothing" rather than falling back to the
  site-wide licence — the wiki cannot license Battlestate's material under
  CC, so claiming it did would assert a grant nobody made.
  """

  require Logger

  alias EftBuddy.Wiki.DumpScript

  @batch 50

  # Cache of title => declaration, including negative results.
  #
  # The negative results are the point. Each sync asks about every image on
  # every page it scrapes — thousands of files — and ~97% of them declare
  # nothing at all, so without a cache each run re-reads the same thousands
  # of file pages to rediscover the same handful of declarations. Caching
  # only the hits would save almost nothing.
  #
  # A TTL rather than a permanent cache because a licence *can* be added to
  # an existing file page upstream; a week means we notice within a week
  # while still collapsing the repeated work of same-day runs and retries.
  @cache :eft_buddy_wiki_file_licenses
  @cache_ttl_ms 7 * 24 * 60 * 60 * 1000
  @no_license :none

  @cc_by_nc_sa_4 %{
    code: :cc_by_nc_sa_4,
    label: "CC BY-NC-SA 4.0",
    url: "https://creativecommons.org/licenses/by-nc-sa/4.0/",
    creditable: true
  }

  # Template name (lowercased, `Copyright ` prefix stripped) => licence.
  #
  # `game` and `fairuse` both mean **Battlestate's material, whatever the
  # file happens to depict** — not "item icons". Of the files tagged `game`
  # that reach a quest or chapter page, only about half are icons; the rest
  # are in-game location screenshots and quest banners. Every file tagged
  # `fairuse` that reaches one is an in-game location screenshot. Both are
  # out of scope for credit by product decision and are covered by the
  # site-wide Battlestate disclaimer in the footer.
  #
  # They are still recognised rather than ignored so that an explicit game
  # tag stays distinguishable from an untagged file. That distinction is
  # informational only: tagging on this wiki is per-uploader habit, not
  # policy, so two identical icons can differ in whether they carry a tag.
  # Never infer anything from the *absence* of one.
  @licenses %{
    "cc-by-nc-sa 4.0" => @cc_by_nc_sa_4,
    "cc-by-sa 3.0" => %{
      code: :cc_by_sa_3,
      label: "CC BY-SA 3.0",
      url: "https://creativecommons.org/licenses/by-sa/3.0/",
      creditable: true
    },
    # `{{Copyright self}}` is a public-domain dedication, not a reservation
    # of rights: the template reads "I, the copyright holder of this work,
    # hereby release it into the public domain." So no attribution is owed —
    # the credit we render is a courtesy, and the label must not imply the
    # uploader retained rights they explicitly gave up.
    "self" => %{
      code: :self,
      label: "Released to the public domain by the uploader",
      url: nil,
      creditable: true
    },
    "pd" => %{
      code: :public_domain,
      label: "Public domain",
      url: nil,
      creditable: true
    },
    "game" => %{code: :game, label: "Game material", url: nil, creditable: false},
    "fairuse" => %{code: :fairuse, label: "Game material", url: nil, creditable: false},
    "nolicense" => %{code: :none, label: nil, url: nil, creditable: false},
    "permission" => %{code: :permission, label: nil, url: nil, creditable: false},
    # No file on the wiki currently declares any of these three, but they are
    # creditable if one ever does — so each carries a licence URL. A
    # creditable licence with a `nil` url would render its name as an
    # unlinked assertion, which is the one thing a credit must not do.
    "gfdl" => %{
      code: :gfdl,
      label: "GFDL 1.3",
      url: "https://www.gnu.org/licenses/fdl-1.3.html",
      creditable: true
    },
    "mit" => %{
      code: :mit,
      label: "MIT",
      url: "https://opensource.org/license/mit",
      creditable: true
    },
    "lgpl" => %{
      code: :lgpl,
      label: "LGPL 3.0",
      url: "https://www.gnu.org/licenses/lgpl-3.0.html",
      creditable: true
    }
  }

  @typedoc "A recognised licence declaration from a file page."
  @type license :: %{
          code: atom(),
          label: String.t() | nil,
          url: String.t() | nil,
          creditable: boolean()
        }

  @doc """
  Fetch licence declarations for `file_titles` (each `"File:Name.ext"`).

  Returns `%{title => license}` containing only files that declared
  something recognised. A file with no template is simply absent.
  """
  @spec fetch([String.t()], keyword()) :: %{String.t() => license()}
  def fetch(file_titles, http_opts) when is_list(file_titles) and is_list(http_opts) do
    titles =
      file_titles
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    ensure_cache()
    {cached, missing} = split_cached(titles)

    fetched =
      missing
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(%{}, fn batch, acc ->
        case fetch_batch(batch, http_opts) do
          {:ok, results} ->
            # Remember the misses too, so the next run does not re-read the
            # same thousands of file pages that declare nothing. This is only
            # safe on a successful response — see the :error clause.
            cache_put(batch, results)
            Map.merge(acc, results)

          :error ->
            # Nothing is cached for a failed batch. Caching an empty result
            # here would turn one transient 503 into a week of missing
            # credits on those files, which is the opposite of the point.
            acc
        end
      end)

    Map.merge(cached, fetched)
  end

  @doc """
  Drop everything cached by `fetch/2`.

  For forcing a re-read from IEx after a licence changes upstream, without
  waiting out the TTL.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    ensure_cache()
    :ets.delete_all_objects(@cache)
    :ok
  end

  @doc """
  The uploaders of any images in a manifest that declare a licence of their own.

  Returns a de-duplicated, sorted list of usernames. The vast majority of
  manifests yield `[]` — only a handful of files on the whole wiki are
  contributor-licensed rather than Battlestate's.

  These names are folded into the page's contributor list in the credit popup.
  An uploader is *not* necessarily a page contributor: `XTychoYT` uploaded the
  CC BY-NC-SA 4.0 map used on the *Tour* chapter but has never edited that page,
  so `prop=contributors` does not return them. Without this they would be
  credited nowhere, which is the one place in the app where that would breach a
  ShareAlike condition rather than just being impolite.

  ## Why it walks the whole manifest

  File entries are nested at different depths depending on which scraper wrote
  the manifest — quest galleries, objective images, chapter section blocks and
  infobox banners all sit in different places, and the shapes differ between the
  wiki and chapter dumps. Walking for the shape (a map carrying a `"license"`)
  rather than for a known path means one implementation covers all of them, and
  a scraper growing a new image location cannot silently drop a credit.
  """
  @spec image_uploaders(map() | nil) :: [String.t()]
  def image_uploaders(manifest) when is_map(manifest) do
    manifest
    |> collect_uploaders([])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def image_uploaders(_), do: []

  defp collect_uploaders(%{} = node, acc) do
    acc =
      case normalize(node["license"] || node[:license]) do
        %{creditable: true} -> [node["uploader"] || node[:uploader] | acc]
        _ -> acc
      end

    Enum.reduce(node, acc, fn {_k, v}, inner -> collect_uploaders(v, inner) end)
  end

  defp collect_uploaders(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_uploaders/2)
  end

  defp collect_uploaders(_other, acc), do: acc

  @doc """
  Parse a file page's wikitext into a licence, or `nil` when it declares
  none.

  ## Examples

      iex> EftBuddy.Wiki.FileLicense.parse("{{Copyright CC-BY-NC-SA 4.0}}").label
      "CC BY-NC-SA 4.0"

      iex> EftBuddy.Wiki.FileLicense.parse("[[Category:Quest banners]]")
      nil
  """
  @spec parse(String.t() | nil) :: license() | nil
  def parse(wikitext) when is_binary(wikitext) do
    case Regex.run(~r/\{\{\s*Copyright[ _]+([^}|\n]+?)\s*(?:\||\}\})/i, wikitext) do
      [_, name] -> Map.get(@licenses, name |> String.trim() |> String.downcase())
      _ -> nil
    end
  end

  def parse(_), do: nil

  # Every `:code` we can emit, keyed by its string form, so a code read back
  # out of JSONB can be turned into the atom it started as. Built from
  # `@licenses` rather than hand-listed so it cannot fall behind.
  #
  # An allowlist and not `String.to_atom/1`: codes arrive from a database
  # column, and minting atoms from stored values is unbounded — the atom
  # table is never garbage collected.
  @codes_by_string Map.new(@licenses, fn {_name, %{code: code}} ->
                     {Atom.to_string(code), code}
                   end)

  @doc """
  Normalise a licence map to atom keys, whichever way it arrives.

  Licences are written atom-keyed by the scraper and read back string-keyed
  out of the `content` JSONB, so anything consuming one at render time has
  to cope with both. Returns `nil` for anything unrecognised.

  `:code` is converted back to an atom as well as the keys. Normalising the
  keys but leaving the value a string was a trap: `normalize(stored)` and
  `normalize(parsed)` would compare unequal, and a `%{code: :game}` pattern
  would quietly never match anything read out of the database — the same
  atom-versus-string mismatch this function exists to absorb.
  """
  @spec normalize(map() | nil) :: license() | nil
  def normalize(nil), do: nil

  def normalize(license) when is_map(license) do
    %{
      code: normalize_code(read(license, :code)),
      label: read(license, :label),
      url: read(license, :url),
      creditable: read(license, :creditable) == true
    }
  end

  def normalize(_), do: nil

  defp normalize_code(code) when is_atom(code), do: code
  defp normalize_code(code) when is_binary(code), do: Map.get(@codes_by_string, code)
  defp normalize_code(_), do: nil

  defp read(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # ── Cache ──────────────────────────────────────────────────────────

  # Created on first use rather than in the supervision tree: this module is
  # also run from `mix run --no-start` dump scripts, where no application is
  # started to own a table. Two scrapers can race here, hence the rescue.
  defp ensure_cache do
    if :ets.whereis(@cache) == :undefined do
      :ets.new(@cache, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp split_cached(titles) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(titles, {%{}, []}, fn title, {hits, misses} ->
      case :ets.lookup(@cache, title) do
        [{^title, value, cached_at}] when now - cached_at < @cache_ttl_ms ->
          case value do
            @no_license -> {hits, misses}
            license -> {Map.put(hits, title, license), misses}
          end

        _ ->
          {hits, [title | misses]}
      end
    end)
  rescue
    ArgumentError -> {%{}, titles}
  end

  defp cache_put(batch, results) do
    now = System.monotonic_time(:millisecond)

    rows =
      Enum.map(batch, fn title ->
        {title, Map.get(results, title, @no_license), now}
      end)

    :ets.insert(@cache, rows)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp fetch_batch(batch, http_opts) do
    params = %{
      "action" => "query",
      "prop" => "revisions",
      "rvprop" => "content",
      "rvslots" => "main",
      "titles" => Enum.join(batch, "|"),
      "format" => "json",
      "formatversion" => "2",
      "redirects" => "1"
    }

    case DumpScript.api_get(params, http_opts) do
      {:ok, body} ->
        # Callers look the result up by the title they asked for, so map
        # normalised/redirected titles back — a file page that redirects
        # would otherwise have its licence filed under a key nobody reads.
        # Same reasoning as `EftBuddy.Wiki.Contributors`.
        original_for = DumpScript.requested_title_resolver(body)

        results =
          (get_in(body, ["query", "pages"]) || [])
          |> Enum.flat_map(fn page ->
            with %{"title" => title} <- page,
                 false <- Map.get(page, "missing", false),
                 content when is_binary(content) <- wikitext(page),
                 %{} = license <- parse(content) do
              [{original_for.(title), license}]
            else
              _ -> []
            end
          end)
          |> Map.new()

        {:ok, results}

      {:error, reason} ->
        # A failed batch costs a credit on at most a handful of images and
        # must not sink the scrape. Signalled distinctly from an empty
        # success so the caller knows not to cache it.
        Logger.warning("[FileLicense] batch failed: #{inspect(reason)}")
        :error
    end
  end

  defp wikitext(page) do
    get_in(page, ["revisions", Access.at(0), "slots", "main", "content"])
  end
end
