defmodule EftBuddy.Chapters.Projection do
  @moduledoc """
  Pure projection of a scraped storyline-chapter manifest (the `content`
  JSONB stored in `wiki_chapters`) into the render-ready shape the
  StorylineLive views consume.

  This is the parsing core that used to live in `EftBuddy.Chapters.Loader`
  (which loaded JSON files into ETS at boot). The data now lives in the
  DB, so the GenServer/ETS/file-IO are gone, but the manifest →
  content_sections / items / banner / summary transformation is
  unchanged — and it still operates on string-keyed maps, which is
  exactly what a JSONB column hands back.

  Storyline mirror of `EftBuddy.Wiki.Projection`. `project/1` is run on
  demand (when a chapter is listed or shown), not cached at boot, so
  there's no warm-up to manage — there are only ~10 chapters and each
  parse is cheap.
  """

  alias EftBuddy.Chapters.SectionParser
  alias EftBuddy.Wiki.{FileLicense, Slug}

  import EftBuddy.Wiki.Markup,
    only: [clean_text: 1, strip_html_tags: 1, normalize_inline_wiki_markup: 1]

  @typedoc """
  One ending a conditional objective block leads to, as the wiki tags it —
  `slug` keys it to the matching section of the Endings page.
  """
  @type ending_badge :: %{slug: String.t(), label: String.t(), file: map() | nil}

  @typedoc "One renderable section of a chapter's walkthrough."
  @type content_section :: %{
          dom_id: String.t(),
          slug: String.t(),
          heading: String.t(),
          level: non_neg_integer(),
          transcluded: boolean(),
          endings: [ending_badge()],
          blocks: [SectionParser.block()]
        }

  @typedoc """
  One ending as the endgame chapter presents it: a tab carrying that
  ending's guide and its rewards.
  """
  @type ending_view :: %{
          slug: String.t(),
          label: String.t(),
          icon: map() | nil,
          guide: content_section() | nil,
          rewards: content_section(),
          counts: %{objectives: non_neg_integer(), images: non_neg_integer()}
        }

  @typedoc "Render-ready projection of one chapter's wiki content."
  @type chapter :: %{
          normalized_name: String.t(),
          chapter_name: String.t(),
          wiki_title: String.t(),
          wiki_link: String.t(),
          contributors: [String.t()],
          image_uploaders: [String.t()],
          banner: %{url: String.t()} | nil,
          summary: String.t() | nil,
          related_links: [%{title: String.t(), slug: String.t()}],
          sections: [map()],
          content_sections: [content_section()],
          items: [
            %{
              name: String.t(),
              page: String.t(),
              amount: String.t() | nil,
              requirement: String.t() | nil,
              found_in_raid: boolean() | nil
            }
          ],
          objective_count: non_neg_integer(),
          image_count: non_neg_integer()
        }

  @doc """
  Project a (string-keyed) chapter manifest into the render-ready map.

  Pre-computes everything the LiveView renders — the parsed
  content_sections, de-duplicated item overview, infobox banner, lore
  summary, and the objective/image counts — and keeps the raw `sections`
  for search / future use.
  """
  @spec project(map()) :: chapter()
  def project(manifest) when is_map(manifest) do
    sections = manifest["sections"] || []
    content_sections = build_content_sections(sections)
    counts = counts(content_sections)

    %{
      normalized_name: manifest["normalized_name"],
      chapter_name: manifest["chapter_name"],
      wiki_title: manifest["wiki_title"],
      wiki_link: manifest["wiki_link"],
      # Authors of this chapter's wiki page (see `EftBuddy.Wiki.Contributors`).
      contributors: manifest["contributors"] || [],
      # See `EftBuddy.Wiki.Projection` — uploaders of contributor-licensed
      # images on this page, folded into the contributor list.
      image_uploaders: FileLicense.image_uploaders(manifest),
      # Infobox banner CDN url, or nil if it wasn't resolved.
      banner: extract_banner(manifest["banner"]),
      # Lore blurb pulled from the Description section's {{quote}}.
      summary: extract_summary(sections),
      # Every non-file wikilink the chapter references, as
      # `[%{title, slug}]`. The LiveView intersects these slugs with
      # real task slugs to render cross-links into the tasks tab.
      related_links: normalize_related(manifest["related_links"]),
      # Raw sections retained for search / future use.
      sections: sections,
      # The walkthrough, rendered faithfully: every non-lead section
      # parsed into ordered heading/prose/list/gallery/items blocks.
      content_sections: content_sections,
      # Every "Related Quest Items" entry across the chapter, de-duped by
      # wiki page, in first-seen order. The chapter page renders the
      # per-section item tables in place from the section blocks above;
      # this flattened list is what the LiveView resolves against the
      # item DB in one query to build its `%{page => item}` index.
      items: aggregate_items(content_sections),
      # What this chapter's own pages add up to. The endgame chapter shows
      # one ending at a time and counts that ending instead — see
      # `ending_views/2`.
      objective_count: counts.objectives,
      image_count: counts.images
    }
  end

  def project(_), do: nil

  @doc """
  What a run of sections adds up to: the objectives a reader will work
  through and the screenshots they will look at.

  Counted from the RENDERED blocks. The dump used to count every bullet
  line in every section's raw wikitext, and MediaWiki hands a parent
  section its children's wikitext as well — so a nested walkthrough
  counted its own steps twice over (Falling Skies claimed 78 for the 36 it
  shows) and The Ticket, which carries four alternative guides, claimed
  483 for a page that renders one of them.

  Gallery images only: "Related Quest Items" icons and inline ending
  badges are not screenshots of the walkthrough, and their images come
  from the tarkov.dev API rather than the wiki anyway.
  """
  @spec counts([content_section()]) :: %{objectives: non_neg_integer(), images: non_neg_integer()}
  def counts(sections) when is_list(sections) do
    Enum.reduce(sections, %{objectives: 0, images: 0}, fn section, acc ->
      Enum.reduce(section.blocks, acc, fn
        %{kind: :list, items: items}, a -> %{a | objectives: a.objectives + length(items)}
        %{kind: :gallery, images: images}, a -> %{a | images: a.images + length(images)}
        _block, a -> a
      end)
    end)
  end

  def counts(_sections), do: %{objectives: 0, images: 0}

  # Flatten every section's `:items` blocks into one de-duplicated list,
  # preserving the order items first appear in the walkthrough.
  defp aggregate_items(content_sections) do
    content_sections
    |> Enum.flat_map(fn section ->
      Enum.flat_map(section.blocks, fn
        %{kind: :items, items: items} -> items
        _ -> []
      end)
    end)
    |> Enum.uniq_by(& &1.page)
  end

  # Parse every renderable section into ordered blocks for the detail
  # page. The lead/infobox section is dropped (its banner + lore blurb
  # are surfaced separately as `banner`/`summary`), and any section that
  # parses to nothing (e.g. a bare transclusion wrapper) is filtered out
  # so we never render an empty heading. A monotonic `dom_id` keeps
  # lightbox ids / section anchors unique even when two sections share a
  # slug (The Ticket has two "If you accept Mr. Kerman's offer…" branches).
  defp build_content_sections(sections) do
    sections
    |> Enum.with_index()
    |> Enum.map(fn {section, idx} ->
      %{
        dom_id: "section-#{idx}",
        slug: section["slug"],
        heading: clean_heading(section["heading"]),
        level: section_level(section["level"]),
        transcluded: transcluded?(section["index"]),
        endings: ending_badges(section),
        blocks: SectionParser.parse(section)
      }
    end)
    |> Enum.reject(fn s -> s.slug == "lead" or s.blocks == [] or s.heading == "" end)
  end

  # The wiki links a conditional objective block to the endings it leads
  # to by putting their icons in the block's own heading:
  #
  #     ===If you accept Mr. Kerman's offer [[File:Savior icon.png|Savior ending|74x74px|link=]]…===
  #
  # That is the only machine-readable connection between a branch's
  # objectives and the ending it produces, and both of the obvious places
  # to read it have already discarded it: the API's section `line` is TOC
  # text with the images dropped, and `clean_heading/1` strips markup by
  # design. So read it off the first line of the section's RETAINED
  # wikitext, which is the one copy of the heading still carrying them.
  @doc """
  Whether a section's own heading carries ending badges.

  Shared with `EftBuddy.Chapters.Sync`, which uses it to decide what is
  worth storing: two copies of this test would drift, and the page would
  quietly lose the blocks the scraper stopped keeping.
  """
  @spec badged_heading?(String.t() | nil) :: boolean()
  def badged_heading?(wikitext), do: heading_line(wikitext) =~ ~r/\[\[(?:File|Image):/i

  defp ending_badges(section) do
    files = file_index(section["files"])

    ~r/\[\[(?:File|Image):([^|\]]+)((?:\|[^|\]]*)*)\]\]/i
    |> Regex.scan(heading_line(section["wikitext"]), capture: :all_but_first)
    |> Enum.map(fn [filename, params] -> ending_badge(filename, params, files) end)
    |> Enum.reject(&(&1.slug == ""))
    |> Enum.uniq_by(& &1.slug)
  end

  defp ending_badge(filename, params, files) do
    # The badge's caption ("Savior ending") names the ending; fall back to
    # the filename ("Savior icon.png") for a badge that carries no caption.
    name =
      case badge_caption(params) do
        "" -> filename_stem(filename)
        caption -> caption
      end

    %{
      # `_ending` is the caption's suffix, not part of the ending's name —
      # the Endings page heads its sections "Savior", not "Savior ending".
      slug: name |> Slug.slugify() |> String.replace(~r/_ending$/, ""),
      label: name,
      file: Map.get(files, normalize_filename(filename))
    }
  end

  # A file reference's parameters are a mix of formatting options and one
  # caption, in any order (`|Savior ending|74x74px|link=`). Only the
  # caption names the ending, so skip anything that reads as an option —
  # otherwise a badge written size-first is "read" as an ending called
  # "74x74px".
  @image_options ~w(thumb thumbnail frame framed frameless border
                    right left center none
                    baseline middle sub super top text-top bottom text-bottom)

  defp badge_caption(params) do
    params
    |> String.split("|", trim: true)
    |> Enum.map(&(&1 |> clean_text() |> String.trim()))
    |> Enum.find("", &caption?/1)
  end

  defp caption?(""), do: false

  defp caption?(param) do
    not (String.downcase(param) in @image_options or
           String.contains?(param, "=") or
           Regex.match?(~r/^\d+(x\d+)?px$/i, param) or
           Regex.match?(~r/^upright/i, param))
  end

  defp filename_stem(filename) do
    filename
    |> String.replace(~r/\.\w+$/, "")
    |> String.replace(~r/\s+icon$/i, "")
    |> String.trim()
  end

  # A section's retained wikitext opens with its own `=== … ===` heading.
  # Anything else (a lead section, a transcluded blob that happens to
  # start mid-page) yields no badges rather than a wrong guess.
  defp heading_line(wikitext) when is_binary(wikitext) do
    first = wikitext |> String.split(~r/\r?\n/, parts: 2) |> List.first() |> to_string()

    if Regex.match?(~r/^\s*={2,}.*={2,}\s*$/, first), do: first, else: ""
  end

  defp heading_line(_), do: ""

  defp file_index(files) when is_list(files),
    do: Map.new(files, fn f -> {normalize_filename(f["wiki_filename"]), f} end)

  defp file_index(_), do: %{}

  # MediaWiki treats `_` and ` ` as equivalent in filenames and the first
  # letter case-insensitively — the same normalization
  # `EftBuddy.Chapters.SectionParser` applies to its own file queues.
  defp normalize_filename(name) when is_binary(name),
    do: name |> String.trim() |> String.replace("_", " ") |> String.downcase()

  defp normalize_filename(_), do: ""

  # A section captured from a transcluded template rather than from the
  # chapter page itself — see `EftBuddy.Chapters.Sync`, which stamps
  # those with a `tmpl:<title>` index.
  defp transcluded?(index), do: index |> to_string() |> String.starts_with?("tmpl:")

  @doc """
  A chapter's branch objectives, in page order — the conditional blocks
  the wiki badges with the endings they lead to.

  The Ticket's `==Objectives==` forks into six such blocks ("If you
  accept Mr. Kerman's offer", "If you refuse Mr. Kerman's offer", …),
  each carrying the icons of the endings it produces. What matters about
  them is precisely what document order cannot show — which ending each
  one is *for* — so they are surfaced on their own, badges and all,
  rather than as six contradictory step lists in a row.

  `ending_slugs` is the set of endings that actually exist (the Endings
  page's section slugs). Every badge on a block must name one of them,
  so a chapter with no endings page yields nothing, and a stray image in
  some unrelated heading can never turn that section into an objective
  block it has nothing to do with.
  """
  @spec branch_objectives([content_section()], Enumerable.t()) :: [content_section()]
  def branch_objectives(sections, ending_slugs) when is_list(sections) do
    slugs = MapSet.new(ending_slugs)

    Enum.filter(sections, &branch_section?(&1, slugs))
  end

  def branch_objectives(_sections, _ending_slugs), do: []

  defp branch_section?(%{endings: [_ | _] = badges}, slugs),
    do: Enum.all?(badges, &MapSet.member?(slugs, &1.slug))

  defp branch_section?(_section, _slugs), do: false

  @doc """
  Build one view per ending — its icon, its branch guide, then its rewards.

  The endgame chapter is four alternative playthroughs wearing one page:
  everything before the fork is shared, everything after belongs to
  exactly one ending, and rendered as a single walkthrough it makes every
  reader scroll past three walkthroughs they will never play. So the page
  becomes one tab per ending, and each tab answers the only two questions
  that ending raises — how do I get it, and what do I get.

  The guide is the branch walkthrough the chapter transcludes for that
  ending. The rewards come from the Endings page, whose per-ending
  section is a superset of the chapter's own copy (it carries the outcome
  blurb too). The ending's icon is lifted off the front of that section
  to label its tab, and the section's own "Rewards" sub-heading dropped,
  because the panel around it already says as much.
  """
  @spec ending_views([content_section()], [content_section()] | nil) :: [ending_view()]
  def ending_views(chapter_sections, ending_sections)
      when is_list(chapter_sections) and is_list(ending_sections) do
    guides = Enum.filter(chapter_sections, & &1.transcluded)

    Enum.map(ending_sections, fn ending ->
      {icon, blocks} = pop_leading_icon(ending.blocks)
      guide = guide_for(guides, ending)

      rewards = %{
        ending
        | dom_id: "rewards-#{ending.slug}",
          heading: "Rewards",
          level: 2,
          blocks: drop_heading(blocks, "rewards")
      }

      %{
        slug: ending.slug,
        label: ending.heading,
        icon: icon,
        guide: guide,
        rewards: rewards,
        # What THIS ending costs and shows, not what the chapter holds for
        # all four - only one of them is ever on screen.
        counts: counts(Enum.reject([guide, rewards], &is_nil/1))
      }
    end)
  end

  def ending_views(_chapter_sections, _ending_sections), do: []

  # The chapter transcludes one complete walkthrough per ending
  # (`Template:The_Ticket_Section_Savior_Guide`) — the only section on
  # the page carrying that ending's name.
  defp guide_for(guides, ending) do
    case Enum.find(guides, &String.contains?(&1.slug, ending.slug)) do
      nil ->
        nil

      guide ->
        # The heading names the ending, because the panel is one of four
        # alternatives and "Guide" alone would not say which one you are
        # reading — the tab above it is the only other clue, and it scrolls away.
        %{
          guide
          | dom_id: "guide-#{ending.slug}",
            heading: "Guide for the #{ending.heading} ending",
            level: 2
        }
    end
  end

  # An Endings-page section opens with the ending's own icon, alone in
  # its gallery. As the tab's label it is worth more than as one more
  # screenshot in the body.
  defp pop_leading_icon([%{kind: :gallery, images: [%{file: file}]} | rest]), do: {file, rest}
  defp pop_leading_icon(blocks), do: {nil, blocks}

  defp drop_heading(blocks, text) do
    Enum.reject(blocks, fn
      %{kind: :heading, text: heading} -> String.downcase(heading) == text
      _ -> false
    end)
  end

  defp section_level(level) when is_integer(level), do: level

  defp section_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, _} -> n
      :error -> 99
    end
  end

  defp section_level(_), do: 99

  # Section headings can carry inline wiki markup (e.g. "Access the port
  # [[Terminal]]"); strip it to plain text for display and anchors.
  #
  # Branch-guide sections are captured from transcluded templates, so
  # their "heading" is the raw template title (e.g.
  # "The_Ticket_Section_Savior_Guide"). Collapse those to the meaningful
  # tail ("Savior Guide") and turn the wiki's underscores into spaces.
  defp clean_heading(heading) when is_binary(heading) do
    heading
    |> strip_html_tags()
    |> normalize_inline_wiki_markup()
    |> strip_template_heading_prefix()
    |> String.replace("_", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_heading(_), do: ""

  defp strip_template_heading_prefix(text) do
    case String.split(text, "_Section_", parts: 2) do
      [_, tail] -> tail
      _ -> text
    end
  end

  defp extract_banner(%{"url" => url}) when is_binary(url) and url != "", do: %{url: url}
  defp extract_banner(_), do: nil

  defp normalize_related(links) when is_list(links) do
    links
    |> Enum.map(fn
      %{"title" => title, "slug" => slug} -> %{title: title, slug: slug}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_related(_), do: []

  # The Description section wraps its lore blurb in a `{{quote|...}}`
  # template. `clean_text`-style template stripping would delete the
  # whole thing, so pull the quote's first positional arg out directly.
  defp extract_summary(sections) do
    with %{"wikitext" => wt} when is_binary(wt) <-
           Enum.find(sections, fn s -> s["slug"] == "description" end),
         [_, inner] <- Regex.run(~r/\{\{\s*quote\s*\|(.+?)\}\}/s, wt) do
      inner
      |> normalize_inline_wiki_markup()
      |> String.split("|")
      |> List.first()
      |> strip_html_tags()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> nil_if_empty()
    else
      _ -> nil
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
end
