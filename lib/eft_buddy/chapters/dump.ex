defmodule EftBuddy.Chapters.Dump do
  @moduledoc """
  Pure, side-effect-free core of the storyline-chapter scrape pipeline,
  driven by `EftBuddy.Chapters.Sync`.

  The sync injects the impure bits — the MediaWiki API calls
  (`:fetch`, `:resolve`), the category enumeration, and the DB upsert
  (`:write`) — so everything here is deterministic and testable.

  Companion to `EftBuddy.Wiki.Dump` (the quest pipeline). Storyline
  chapters (e.g. "Boreas", "The Unheard") are wiki-only editorial pages
  grouped under `Category:Story chapters`; they do NOT exist as tasks in
  the tarkov.dev API, so this pipeline never matches against the Repo.
  The chapter set is enumerated live from the category rather than
  hardcoded, so a new chapter shipped by BSG is picked up automatically.

  Each chapter is assembled into a manifest whose shape mirrors the quest
  manifest (per-section `wikitext` is retained so
  `EftBuddy.Chapters.Projection` can re-parse galleries/guide blocks
  without re-hitting the wiki). The sync persists that manifest as the
  `content` JSONB of a `wiki_chapters` row.
  """

  @category "Category:Story chapters"

  alias EftBuddy.Wiki.Slug

  import EftBuddy.Wiki.Markup,
    only: [clean_text: 1, strip_inline_file_refs: 1, strip_html_comments: 1, strip_nowiki: 1]

  @doc "The wiki category the storyline chapters are enumerated from."
  def category, do: @category

  # ── Chapter set (built from live category enumeration) ──────────────

  @doc """
  Turn the raw page titles returned by a `Category:Story chapters`
  enumeration into the chapter structs the pipeline operates on,
  dropping the self-titled hub page, de-duplicating by slug, and
  sorting by display title for a stable run order.
  """
  def build_chapters(titles) when is_list(titles) do
    titles
    |> Enum.reject(&hub_page?/1)
    |> Enum.map(&chapter_from_title/1)
    |> Enum.uniq_by(& &1.normalized_name)
    |> Enum.sort_by(& &1.title)
  end

  @doc """
  The category index page (`Story chapters`) is itself a member of the
  category; it's a hub, not a chapter, so it's excluded from the set.
  """
  def hub_page?(title), do: String.trim(title) == "Story chapters"

  @doc """
  Build a chapter struct from a wiki page title.

  `wiki_title` is the real page title used for API fetches; `title` is
  the cleaned display title (the ` (story chapter)` disambiguation
  suffix on "The Labyrinth (story chapter)" is stripped); and
  `normalized_name` is the slug the loader/app key on.
  """
  def chapter_from_title(wiki_title) when is_binary(wiki_title) do
    display = display_title(wiki_title)

    %{
      wiki_title: wiki_title,
      title: display,
      normalized_name: normalize_name(display),
      wiki_link:
        "https://escapefromtarkov.fandom.com/wiki/" <> String.replace(wiki_title, " ", "_")
    }
  end

  defp display_title(wiki_title) do
    wiki_title
    |> String.replace(~r/\s*\(story chapter\)\s*$/i, "")
    |> String.trim()
  end

  @doc """
  Narrow a chapter list down to a single `--chapter` selection (matched
  by slug). Returns the full list when no selection is given, or
  `{:unrecognized, value}` when the slug matches nothing — so the runner
  can fail loudly without processing anything.
  """
  def select_chapters(chapters, nil), do: chapters

  def select_chapters(chapters, value) when is_binary(value) do
    target = normalize_name(value)

    case Enum.filter(chapters, &(&1.normalized_name == target)) do
      [] -> {:unrecognized, value}
      selected -> selected
    end
  end

  # ── Orchestration ──────────────────────────────────────────────────

  @doc """
  Process every chapter, isolating failures so one bad page never
  aborts the run.

  Required injected functions (keep this module pure):

    * `:fetch`   — `chapter -> {:ok, %{lead_wikitext, sections}} | {:error, reason}`
    * `:resolve` — `[bare_filename] -> %{bare_filename => imageinfo}`
    * `:write`   — `(chapter, manifest) -> :ok | {:error, reason}`

  Options: `:dry_run` (skip image resolution + write).

  Returns `%{failures: [%{slug, reason}], summary: %{processed, failed}}`.
  """
  def run(chapters, opts) when is_list(chapters) do
    fetch = Keyword.fetch!(opts, :fetch)
    resolve = Keyword.fetch!(opts, :resolve)
    write = Keyword.fetch!(opts, :write)
    dry_run? = !!Keyword.get(opts, :dry_run, false)

    {failures, processed} =
      Enum.reduce(chapters, {[], 0}, fn chapter, {failures, processed} ->
        case process_one(chapter, fetch, resolve, write, dry_run?) do
          :ok ->
            {failures, processed + 1}

          {:error, reason} ->
            {[%{slug: chapter.normalized_name, reason: reason} | failures], processed}
        end
      end)

    failures = Enum.reverse(failures)

    %{
      failures: failures,
      summary: %{processed: processed, failed: length(failures)}
    }
  end

  defp process_one(chapter, fetch, resolve, write, dry_run?) do
    case fetch.(chapter) do
      {:ok, fetched} ->
        parsed = parse_sections(fetched)
        resolved = if dry_run?, do: %{}, else: resolve.(parsed.image_filenames)
        manifest = build_manifest(chapter, parsed, resolved)
        if dry_run?, do: :ok, else: write.(chapter, manifest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Section parsing ────────────────────────────────────────────────

  @doc """
  Parse a fetched chapter page into structured sections.

  Input is the `:fetch` payload — `%{lead_wikitext, sections}` where
  `sections` is the API's non-lead section list (each
  `%{index, heading, level, wikitext}`). The lead/infobox is synthesized
  as section `"0"` (the API never lists it).

  Returns `%{sections, image_filenames, related_links}`:

    * `sections` — per-section maps with extracted `objectives`, image
      `files`, non-file `links`, and the retained raw `wikitext`.
    * `image_filenames` — de-duplicated bare filenames to resolve.
    * `related_links` — de-duplicated non-file wikilink targets
      (`%{title, slug}`), used later to cross-link chapters to tasks.
  """
  def parse_sections(%{lead_wikitext: lead, sections: sections}) do
    lead = lead || ""

    raw =
      [%{index: "0", heading: "(lead / infobox)", level: "0", wikitext: lead}] ++
        Enum.map(sections, fn s ->
          %{
            index: to_string(Map.get(s, :index, "")),
            heading: s.heading,
            level: to_string(s.level),
            wikitext: s.wikitext || ""
          }
        end)

    parsed =
      raw
      |> Enum.map(&parse_one_section/1)
      |> inject_banner(lead)

    image_filenames =
      parsed |> Enum.flat_map(& &1.files) |> Enum.map(& &1.wiki_filename) |> Enum.uniq()

    related_links =
      parsed |> Enum.flat_map(& &1.links) |> Enum.uniq_by(& &1.slug)

    %{sections: parsed, image_filenames: image_filenames, related_links: related_links}
  end

  defp parse_one_section(s) do
    cleaned = s.wikitext |> strip_html_comments() |> strip_nowiki()

    # Exclude "Related Quest Items" wikitable icons from the dumped
    # files: those item images come from the tarkov.dev API at render
    # time (resolved by name), so resolving/storing them here is wasted
    # and would inflate the per-chapter image count. Galleries and
    # standalone guide thumbnails are never inside `{| … |}` tables, so
    # stripping tables for file extraction leaves them untouched.
    file_source = strip_wikitables(cleaned)

    files =
      (extract_image_filenames(file_source) ++ extract_gallery_filenames(file_source))
      |> Enum.uniq()
      |> Enum.map(fn name -> %{wiki_filename: name, banner: false} end)

    %{
      index: s.index,
      heading: s.heading,
      level: s.level,
      slug: slug_for_section(s),
      objectives: extract_objectives(cleaned),
      files: files,
      links: extract_links(cleaned),
      wikitext: s.wikitext
    }
  end

  # Blank out `{| … |}` wikitables (non-nesting; chapter tables are
  # flat) so image extraction skips the item icons inside them.
  defp strip_wikitables(wikitext) do
    Regex.replace(~r/\{\|.*?\|\}/s, wikitext, " ")
  end

  # Bullet/numbered list items, in document order. Unlike the quest
  # parser (which keeps only top-level objectives), chapter walkthroughs
  # nest objectives several levels deep, so `level` (marker depth) is
  # retained for the loader to rebuild the hierarchy.
  defp extract_objectives(wikitext) do
    wikitext
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({[], 0}, fn line, {acc, idx} ->
      case Regex.run(~r/^([*#]+)\s*(.*)$/, String.trim_leading(line)) do
        [_, markers, text] ->
          case clean_text(strip_inline_file_refs(text)) do
            "" ->
              {acc, idx}

            cleaned ->
              new_idx = idx + 1
              {[%{index: new_idx, level: String.length(markers), text: cleaned} | acc], new_idx}
          end

        _ ->
          {acc, idx}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Bare `File:`/`Image:` filenames referenced anywhere in the wikitext.
  # We capture only the filename (up to the first `|` or `]`), so nested
  # `[[...]]` links inside an image caption never confuse the match.
  defp extract_image_filenames(wikitext) do
    ~r/\[\[\s*(?:file|image)\s*:\s*([^\]\|\n]+)/i
    |> Regex.scan(wikitext, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&normalize_filename/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Filenames referenced inside `<gallery>...</gallery>` blocks. Unlike
  # ordinary wikilinks, gallery entries are bare lines (`File:Foo.png|caption`
  # or even just `Foo.png|caption`, the `File:` prefix being optional
  # inside a gallery), so the `[[File:...]]` extractor above misses them
  # entirely — which is why chapter walkthrough screenshots were absent
  # from the manifest. We pull the filename off each non-empty gallery
  # line (everything before the first `|` caption separator) and
  # normalize it the same way, so it matches the resolved-url map and the
  # loader's per-filename queue.
  defp extract_gallery_filenames(wikitext) do
    ~r/<gallery[^>]*>(.*?)<\/gallery>/is
    |> Regex.scan(wikitext, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn body ->
      body
      |> String.split(~r/\r?\n/)
      |> Enum.map(&gallery_entry_filename/1)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp gallery_entry_filename(line) do
    line
    |> String.trim()
    |> String.split("|")
    |> List.first()
    |> normalize_filename()
  end

  # Non-file wikilink targets (`[[Quest Name]]`, `[[Quest|label]]`),
  # anchors stripped. Anything namespaced (File:, Category:, interwiki
  # `cs:`...) is dropped via the colon check. These are kept so the app
  # can cross-link a chapter to the real tasks it references.
  defp extract_links(wikitext) do
    ~r/\[\[([^\]\|\n]+)(?:\|[^\]\n]*)?\]\]/
    |> Regex.scan(wikitext, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(fn target -> target |> String.split("#") |> List.first() |> String.trim() end)
    |> Enum.reject(fn target -> target == "" or String.contains?(target, ":") end)
    |> Enum.map(fn title -> %{title: title, slug: normalize_name(title)} end)
    |> Enum.reject(&(&1.slug == ""))
    |> Enum.uniq_by(& &1.slug)
  end

  # The chapter banner lives in the infobox `|image =` param. Chapters
  # have no API-backed image (they aren't tasks), so the banner is
  # always captured and flagged on the lead section's file list for URL
  # resolution.
  defp inject_banner(parsed, lead_wikitext) do
    case extract_banner_filename(lead_wikitext) do
      nil ->
        parsed

      banner ->
        Enum.map(parsed, fn
          %{slug: "lead"} = s ->
            files = [
              %{wiki_filename: banner, banner: true}
              | Enum.reject(s.files, &(&1.wiki_filename == banner))
            ]

            %{s | files: files}

          s ->
            s
        end)
    end
  end

  defp extract_banner_filename(wikitext) do
    with [_, raw] <- Regex.run(~r/^[ \t]*\|[ \t]*image[ \t]*=[ \t]*(.*)$/im, wikitext),
         value when value != "" <- String.trim(raw) do
      case value |> strip_link_wrapper() |> normalize_filename() do
        "" -> nil
        name -> name
      end
    else
      _ -> nil
    end
  end

  defp strip_link_wrapper(value) do
    case Regex.run(~r/\[\[\s*(?:file|image)\s*:\s*([^\]\|]+)/i, value) do
      [_, inner] -> String.trim(inner)
      _ -> value
    end
  end

  # ── Manifest assembly ──────────────────────────────────────────────

  @doc """
  Assemble the chapter manifest from a chapter, its parsed sections, and
  the resolved image-URL map (`%{bare_filename => iinfo}`).

  Shape mirrors the quest manifest: per-section `wikitext` is retained
  so `EftBuddy.Chapters.Projection` can re-parse without re-fetching,
  `files` carry resolved CDN URLs, and a top-level `banner` +
  `related_links` are surfaced for convenient rendering / cross-linking.
  The sync stores this map as the `content` JSONB of a `wiki_chapters`
  row.
  """
  def build_manifest(chapter, parsed, resolved) do
    sections =
      Enum.map(parsed.sections, fn s ->
        %{
          index: s.index,
          heading: s.heading,
          level: s.level,
          slug: s.slug,
          objectives:
            Enum.map(s.objectives, fn o -> %{index: o.index, level: o.level, text: o.text} end),
          files: Enum.map(s.files, &serialize_file(&1, resolved)),
          wikitext: s.wikitext
        }
      end)

    total_files = parsed.sections |> Enum.flat_map(& &1.files) |> length()
    total_objectives = parsed.sections |> Enum.flat_map(& &1.objectives) |> length()

    %{
      chapter_name: chapter.title,
      normalized_name: chapter.normalized_name,
      wiki_title: chapter.wiki_title,
      wiki_link: chapter.wiki_link,
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      banner: banner_for(parsed.sections, resolved),
      # Every non-file wikilink the chapter references (`%{title, slug}`).
      # NOT pre-filtered to quests — the dump never touches the DB — so
      # the app cross-references these slugs against task slugs to render
      # links into the tasks tab.
      related_links: parsed.related_links,
      sections: sections,
      summary: %{
        total_sections: length(sections),
        total_objectives: total_objectives,
        total_files: total_files,
        total_images: map_size(resolved)
      }
    }
  end

  defp serialize_file(f, resolved) do
    iinfo = Map.get(resolved, f.wiki_filename) || %{}

    %{
      banner: Map.get(f, :banner, false),
      wiki_filename: f.wiki_filename,
      wiki_title: "File:" <> f.wiki_filename,
      url: iinfo["url"],
      mime: iinfo["mime"],
      width: iinfo["width"],
      height: iinfo["height"],
      # See `EftBuddy.Wiki.Dump.serialize_file/2` — same credit fields,
      # nil for any file that declares no licence of its own.
      description_url: iinfo["descriptionurl"],
      uploader: iinfo["user"],
      license: iinfo["license"]
    }
  end

  defp banner_for(sections, resolved) do
    sections
    |> Enum.flat_map(& &1.files)
    |> Enum.find(&Map.get(&1, :banner, false))
    |> case do
      nil ->
        nil

      f ->
        iinfo = Map.get(resolved, f.wiki_filename) || %{}

        %{
          wiki_filename: f.wiki_filename,
          url: iinfo["url"],
          mime: iinfo["mime"],
          width: iinfo["width"],
          height: iinfo["height"]
        }
    end
  end

  # ── Text / slug / filename helpers (mirror the quest pipeline) ──────

  defp slug_for_section(%{heading: "(lead / infobox)"}), do: "lead"

  defp slug_for_section(%{heading: heading}) do
    case heading |> clean_text() |> Slug.slugify() do
      "" -> "section"
      s -> s
    end
  end

  defp normalize_name(name), do: Slug.normalize_name(name)

  # Strip any (possibly repeated/typo'd) File:/Image: prefix and
  # canonicalize the way MediaWiki does: underscores become spaces and
  # the first letter is upper-cased. Applied consistently to both the
  # filename we resolve and the manifest key so lookups always match.
  defp normalize_filename(name) do
    name
    |> String.trim()
    |> do_strip_filename_prefix()
    |> String.replace("_", " ")
    |> String.trim()
    |> upcase_first()
  end

  defp do_strip_filename_prefix(name) do
    case Regex.run(~r/^\s*(?:file|image)\s*:\s*(.*)$/is, name) do
      [_, rest] -> do_strip_filename_prefix(rest)
      _ -> name
    end
  end

  defp upcase_first(""), do: ""
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  @doc """
  Sanitise a chapter title into a filesystem-safe directory name
  (filesystem-illegal characters become dashes, whitespace collapsed).

  Mirrors `EftBuddy.Wiki.Dump.sanitize_dirname/1` exactly so the two
  dump pipelines lay out their folders the same way. The directory name
  is cosmetic — both loaders key their ETS tables on the manifest's
  `normalized_name`, not the folder — but keeping the convention shared
  avoids surprises.
  """
  def sanitize_dirname(name) do
    name
    |> String.replace(~r/[\/\\:*?"<>|]/, "-")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
