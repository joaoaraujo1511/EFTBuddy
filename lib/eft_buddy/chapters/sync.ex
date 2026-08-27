defmodule EftBuddy.Chapters.Sync do
  @moduledoc """
  Scrapes storyline-chapter walkthroughs from the EFT Fandom wiki and
  upserts them into `wiki_chapters`. Replaces the old offline
  `scripts/dump_wiki_chapters.exs` script + committed JSON manifests
  (`priv/static/storyline-dump/`) + boot-time ETS load.

  Storyline counterpart to `EftBuddy.Wiki.Sync`, and scheduled the same
  way: a background run a short while after boot, then daily. Can also be
  triggered synchronously from IEx:

      EftBuddy.Chapters.Sync.run()

  Pipeline (all the pure parts are reused from `EftBuddy.Chapters.Dump`
  so this module is only the impure glue):

    1. Enumerate `Category:Story chapters` from the wiki and build the
       chapter set (`EftBuddy.Chapters.Dump.build_chapters/1`), plus the
       standalone "Endings" reference page.
    2. For each page, fetch its sections (including any transcluded guide
       templates), parse + assemble a manifest (`EftBuddy.Chapters.Dump`),
       and upsert a `wiki_chapters` row keyed by the chapter slug.
    3. Prune rows for chapters that have vanished from the wiki.

  ## Difference from the quest sync

  Chapters are wiki-only editorial pages — they have NO tarkov.dev task
  behind them — so this sync never reads the `tasks` table, has no
  `:no_tasks` guard, and persists no `task_id` / `wip` / karma columns.
  Cross-links to the real tasks a chapter mentions are resolved at read
  time from the manifest's `related_links`.

  ## Defensiveness

  A scrape that can't enumerate the category must never wipe good rows:
  if enumeration returns an empty set (API down / category renamed) we
  skip the run and keep the existing rows, retrying on the normal
  cadence. The "Endings" reference page is only appended *after* a
  successful enumeration, so an API outage can't reduce the table to just
  that page. A single chapter whose fetch fails is isolated by
  `EftBuddy.Chapters.Dump.run/2`, and its existing row is preserved by
  the prune (its slug is still in the processed set).
  """

  # First of the three Fandom scrapes, and `:ran` like every other feed:
  # Bootstrap runs it inside the cold start rather than releasing it afterwards,
  # so the stagger below is purely this feed's slot in the recurring cycle. The
  # storyline has no DB dependency and is the smallest set, so it leads the
  # group, ahead of the heavier events and quest scrapes.
  use EftBuddy.Sync.Scheduler,
    label: "ChaptersSync",
    interval: 24 * 60 * 60 * 1_000,
    stagger: 0,
    bootstrap: :ran,
    config_key: :chapters

  require Logger
  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Chapters.{ChapterPage, Dump, Projection}
  alias EftBuddy.Wiki.{Contributors, DumpScript, FileLicense}
  alias EftBuddy.Sync.Reporter

  @api_url "https://escapefromtarkov.fandom.com/api.php"
  @imageinfo_batch 50

  # Reference pages outside `Category:Story chapters` that we still want
  # scraped through the same pipeline. "Endings" is the wiki's overview
  # of the four story endings (the Smokey flowchart + each ending's
  # description and rewards); it's surfaced under the storyline "Endings"
  # tab, NOT as a chapter in the timeline.
  @extra_pages ["Endings"]

  # Slug of the chapter the four endings branch from — the one page this
  # sync does not store whole. Mirrors `EftBuddy.Chapters`, which owns the
  # read side of the same fact.
  @endgame_slug "the-ticket"

  @replace_on_conflict [:chapter_name, :content, :updated_at]

  @impl EftBuddy.Sync.Scheduler
  # Returns `{:ok, summary}`, `{:error, :empty_enumeration}` or
  # `{:error, reason}`. `run/0` (from `EftBuddy.Sync.Scheduler`) wraps this in the
  # cluster-wide lock.
  def do_run do
    titles = DumpScript.enumerate_category_members(Dump.category(), http_opts())

    if titles == [] do
      Logger.error(
        "[#{prefix()}] enumerated 0 chapters from #{Dump.category()} (API down or category renamed?); keeping existing rows."
      )

      {:error, :empty_enumeration}
    else
      # Append the standalone reference pages only after a successful
      # enumeration, and de-dupe by slug so a reference page that also
      # happens to be a category member isn't scraped twice.
      chapters =
        (Dump.build_chapters(titles) ++ extra_pages())
        |> Enum.uniq_by(& &1.normalized_name)

      scrape_and_upsert(chapters)
    end
  end

  defp extra_pages, do: Enum.map(@extra_pages, &Dump.chapter_from_title/1)

  defp scrape_and_upsert(chapters) do
    Reporter.with_run("ChaptersSync", fn ->
      # One batched pass for all ~11 chapter pages, before the per-chapter
      # scrape, so each chapter's credits name its own authors.
      rosters = Contributors.fetch(Enum.map(chapters, & &1.wiki_title), http_opts())

      result =
        Dump.run(chapters,
          fetch: &fetch_chapter/1,
          resolve: &resolve_image_urls/1,
          prune: &prune_sections/2,
          write: &upsert_chapter(&1, &2, rosters)
        )

      pruned = prune(chapters)

      {:ok,
       %{
         processed: result.summary.processed,
         failed: result.summary.failed,
         pruned: pruned
       }}
    end)
  end

  # Delete rows for chapters no longer present on the wiki. Safe because
  # `chapters` covers every enumerated page (a page whose fetch failed is
  # still in this set, so its prior row is preserved), and we only get
  # here when enumeration returned a non-empty set.
  defp prune(chapters) do
    slugs = Enum.map(chapters, & &1.normalized_name)

    {deleted, _} =
      Repo.delete_all(from(c in ChapterPage, where: c.normalized_name not in ^slugs))

    deleted
  end

  # ── Injected prune: what is worth storing ──────────────────────────

  # Every chapter but one is rendered whole, as a walkthrough, so nothing
  # is dropped.
  #
  # The endgame chapter is not: its page is a guide per ending, and the
  # storyline index lists the conditional blocks the story forks into.
  # Nothing renders the rest — the shared objective list, the tabber
  # intro, the dozen closing steps every ending shares, or the per-ending
  # rewards the Endings page already carries verbatim. Storing them cost
  # 136 kB of JSONB and 129 image lookups a day for content no route can
  # reach.
  #
  # Anchored on the slug rather than inferred from the page. The inferred
  # rule — "a chapter with badges in its headings keeps only its badged
  # sections" — would silently gut any other chapter the first time an
  # editor put an icon in one of its headings, and losing a walkthrough
  # to a cosmetic wiki edit is not a trade worth making to avoid naming
  # one slug.
  defp prune_sections(%{normalized_name: @endgame_slug}, sections) do
    case Enum.filter(sections, &endgame_section?/1) do
      [] ->
        # The page was restructured and the rule now matches nothing.
        # Keeping everything renders too much; keeping nothing renders an
        # empty chapter, and only one of those is recoverable by looking
        # at the site.
        Reporter.silent_warn(
          "[#{prefix()}] #{@endgame_slug}: no branch sections matched; keeping the whole page."
        )

        sections

      kept ->
        kept
    end
  end

  defp prune_sections(_chapter, sections), do: sections

  # The lead carries the infobox banner; a `tmpl:` section is one of the
  # transcluded branch guides; and a section whose own heading carries
  # ending icons is one of the conditional blocks. Everything else on that
  # page has no route.
  defp endgame_section?(%{index: "0"}), do: true
  defp endgame_section?(%{index: "tmpl:" <> _}), do: true
  defp endgame_section?(%{wikitext: wikitext}), do: Projection.badged_heading?(wikitext)

  # ── Injected write: upsert one chapter's manifest as a row ─────────

  defp upsert_chapter(chapter, manifest, rosters) do
    # Round-trip the atom-keyed manifest through JSON so `content` is
    # stored string-keyed (exactly what a JSONB read returns) and the
    # projection sees the same shape as at read time.
    content =
      manifest
      |> Contributors.merge(Map.get(rosters, chapter.wiki_title))
      |> Jason.encode!()
      |> Jason.decode!()

    attrs = %{
      normalized_name: chapter.normalized_name,
      chapter_name: chapter.title,
      content: content
    }

    %ChapterPage{}
    |> ChapterPage.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @replace_on_conflict},
      conflict_target: :normalized_name
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  # ── Wiki HTTP (impure glue, mirrors the old runner) ────

  defp http_opts, do: [url: @api_url, user_agent: DumpScript.user_agent()]

  # Fetch and assemble a chapter's `parse_sections/1` payload: the
  # lead/infobox wikitext (section 0) plus the wikitext of every other
  # section, in the order the page presents them.
  defp fetch_chapter(chapter) do
    title = chapter.wiki_title

    with {:ok, raw_sections} <- fetch_sections(title),
         {:ok, lead_wikitext} <- fetch_wikitext_section(title, "0") do
      {:ok, %{lead_wikitext: lead_wikitext, sections: fetch_section_bodies(title, raw_sections)}}
    end
  end

  # `action=parse&prop=sections` — the non-lead section list. The lead /
  # infobox is synthesized separately (it isn't in the API's list) by
  # `EftBuddy.Chapters.Dump.parse_sections/1`.
  defp fetch_sections(title) do
    case DumpScript.api_get(
           %{
             "action" => "parse",
             "page" => title,
             "prop" => "sections",
             "format" => "json",
             "formatversion" => "2"
           },
           http_opts()
         ) do
      {:ok, %{"error" => %{"info" => msg}}} ->
        {:error, msg}

      {:ok, body} ->
        list =
          (get_in(body, ["parse", "sections"]) || [])
          |> Enum.map(fn s ->
            %{index: s["index"], heading: s["line"], level: s["level"], fromtitle: s["fromtitle"]}
          end)

        {:ok, list}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `action=parse&prop=wikitext&section=N` — the raw wikitext of one
  # section, returned byte-for-byte for `parse_sections/1` to retain
  # unmodified.
  defp fetch_wikitext_section(title, section_index) do
    case DumpScript.api_get(
           %{
             "action" => "parse",
             "page" => title,
             "prop" => "wikitext",
             "section" => section_index,
             "format" => "json",
             "formatversion" => "2"
           },
           http_opts()
         ) do
      {:ok, %{"error" => %{"info" => msg}}} ->
        {:error, msg}

      {:ok, body} ->
        {:ok, get_in(body, ["parse", "wikitext"]) || ""}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Turn the API's section list into the ordered list of wikitext fetches
  that reproduces the page: `{:own, section}` for one of the page's own
  sections, `{:template, title}` for a whole transcluded template.

  Some chapter pages (e.g. "The Ticket") build their branch walkthroughs
  by transcluding guide templates. MediaWiki lists those with `T-N`
  section indices that CANNOT be fetched by index (the API answers
  "there is no section T-N"), so the FIRST `T-N` of a template stands in
  for the whole template page and its remaining slices are dropped.

  Position is the whole point of doing this in one ordered pass rather
  than as "every own section, then every template": The Ticket
  transcludes its four branch guides *inside* `==Guide==`, ahead of the
  shared closing steps. Appending them after the page's own sections
  left the "Guide" heading introducing four ending icons and nothing
  else, with the entire walkthrough stranded at the foot of the page
  below the endings.

  Public only so it can be tested without HTTP.
  """
  @spec fetch_plan([map()]) :: [{:own, map()} | {:template, String.t()}]
  def fetch_plan(raw_sections) do
    {plan, _seen} =
      Enum.reduce(raw_sections, {[], MapSet.new()}, fn s, {acc, seen} ->
        cond do
          integer_index?(s.index) ->
            {[{:own, s} | acc], seen}

          is_nil(s.fromtitle) or MapSet.member?(seen, s.fromtitle) ->
            {acc, seen}

          true ->
            {[{:template, s.fromtitle} | acc], MapSet.put(seen, s.fromtitle)}
        end
      end)

    Enum.reverse(plan)
  end

  # Run the plan. A per-section error is logged and skipped rather than
  # failing the whole chapter — one odd section shouldn't lose an entire
  # chapter's content. (A failure of the page-level
  # `fetch_sections`/lead fetch still fails the chapter.)
  defp fetch_section_bodies(title, raw_sections) do
    raw_sections
    |> fetch_plan()
    |> Enum.reduce([], fn
      {:own, s}, acc -> prepend_own_section(title, s, acc)
      {:template, tmpl}, acc -> prepend_template_section(tmpl, acc)
    end)
    |> Enum.reverse()
  end

  defp integer_index?(index), do: to_string(index) =~ ~r/^\d+$/

  defp prepend_own_section(title, s, acc) do
    case fetch_wikitext_section(title, s.index) do
      {:ok, wikitext} ->
        [%{index: s.index, heading: s.heading, level: s.level, wikitext: wikitext} | acc]

      {:error, reason} ->
        Reporter.silent_warn(
          "[#{prefix()}] section skipped: #{s.heading} (#{s.index}) — #{inspect(reason)}"
        )

        acc
    end
  end

  # One transcluded guide template, fetched as a whole page and turned
  # into a single synthetic section, so branch-guide walkthroughs (e.g.
  # The Ticket's Savior/Debtor/Survivor/Fallen paths) are captured. The
  # heading is the template title minus the `Template:` namespace, and
  # the `tmpl:` index is what tells the downstream parser to keep the
  # blob's own sub-headings — they are never dumped separately.
  defp prepend_template_section(tmpl, acc) do
    case fetch_page_wikitext(tmpl) do
      {:ok, wikitext} ->
        [
          %{
            index: "tmpl:" <> tmpl,
            heading: template_heading(tmpl),
            level: "2",
            wikitext: wikitext
          }
          | acc
        ]

      {:error, reason} ->
        Reporter.silent_warn("[#{prefix()}] template skipped: #{tmpl} — #{inspect(reason)}")
        acc
    end
  end

  defp template_heading("Template:" <> rest), do: rest
  defp template_heading(title), do: title

  # `action=parse&prop=wikitext` for a whole page (no section), used for
  # transcluded templates whose sections aren't individually fetchable.
  defp fetch_page_wikitext(title) do
    case DumpScript.api_get(
           %{
             "action" => "parse",
             "page" => title,
             "prop" => "wikitext",
             "format" => "json",
             "formatversion" => "2"
           },
           http_opts()
         ) do
      {:ok, %{"error" => %{"info" => msg}}} -> {:error, msg}
      {:ok, body} -> {:ok, get_in(body, ["parse", "wikitext"]) || ""}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Image resolution (metadata-only; no binaries downloaded) ───────

  # Resolve a de-duplicated list of bare wiki filenames to their CDN
  # image info via batched `action=query&prop=imageinfo`. The result is
  # keyed by the SAME bare filename the caller passed, so
  # `EftBuddy.Chapters.Dump.build_manifest/3` can look each one up. Files
  # missing on the wiki, or whose batch fails, are simply absent from the
  # map (the manifest records those with a `nil` url).
  defp resolve_image_urls(filenames) do
    filenames
    |> Enum.uniq()
    |> Enum.chunk_every(@imageinfo_batch)
    |> Enum.flat_map(&resolve_image_batch/1)
    |> Map.new()
    |> merge_file_licenses()
  end

  # Keys here are bare filenames, so prefix for the licence lookup and map
  # the result back onto the bare key the manifest uses.
  defp merge_file_licenses(info) do
    licenses =
      info
      |> Map.keys()
      |> Enum.map(&("File:" <> &1))
      |> FileLicense.fetch(http_opts())
      |> Map.new(fn {title, license} -> {strip_file_prefix(title), license} end)

    Map.new(info, fn {filename, iinfo} ->
      {filename, Map.put(iinfo, "license", Map.get(licenses, filename))}
    end)
  end

  defp resolve_image_batch(batch) do
    titles = Enum.map(batch, &("File:" <> &1))

    case DumpScript.api_get(
           %{
             "action" => "query",
             "titles" => Enum.join(titles, "|"),
             "prop" => "imageinfo",
             "iiprop" => "url|size|mime|user",
             "format" => "json",
             "formatversion" => "2",
             "redirects" => "1"
           },
           http_opts()
         ) do
      {:ok, body} ->
        # MediaWiki normalizes titles and follows redirects before
        # answering, surfacing both rewrites as `{from, to}` pairs. Invert
        # them so each returned page title maps back to whatever we sent,
        # then strip the "File:" prefix to recover the bare filename key.
        rewrites =
          ((get_in(body, ["query", "normalized"]) || []) ++
             (get_in(body, ["query", "redirects"]) || []))
          |> Map.new(fn %{"from" => from, "to" => to} -> {to, from} end)

        original_for = fn title ->
          Enum.reduce_while(1..5, title, fn _, current ->
            case Map.get(rewrites, current) do
              nil -> {:halt, current}
              prev -> {:cont, prev}
            end
          end)
        end

        (get_in(body, ["query", "pages"]) || [])
        |> Enum.flat_map(fn
          %{"missing" => true} ->
            []

          %{"title" => t, "imageinfo" => [iinfo | _]} ->
            [{strip_file_prefix(original_for.(t)), iinfo}]

          _ ->
            []
        end)

      {:error, reason} ->
        Reporter.silent_warn("[#{prefix()}] imageinfo batch failed: #{inspect(reason)}")
        []
    end
  end

  # MediaWiki accepts `Image:` as an alias for `File:`, so match either rather
  # than a literal `"File:"`. Getting this wrong re-prefixes an aliased title
  # ("File:Image:Foo.png") and the licence lookup silently misses.
  defp strip_file_prefix(title) when is_binary(title) do
    String.replace(title, ~r/^\s*(?:File|Image)\s*:\s*/i, "")
  end

  defp strip_file_prefix(other), do: other

  # ── Cluster-wide lock (mirrors Wiki.Sync / Items.Sync) ─
end
