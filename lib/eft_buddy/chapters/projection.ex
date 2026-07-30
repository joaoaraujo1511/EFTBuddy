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
  alias EftBuddy.Wiki.FileLicense

  import EftBuddy.Wiki.Markup, only: [strip_html_tags: 1, normalize_inline_wiki_markup: 1]

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
          content_sections: [
            %{
              dom_id: String.t(),
              slug: String.t(),
              heading: String.t(),
              level: non_neg_integer(),
              blocks: [SectionParser.block()]
            }
          ],
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
    summary_data = manifest["summary"] || %{}
    content_sections = build_content_sections(sections)

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
      objective_count: summary_data["total_objectives"] || 0,
      # Count only the object/guide images actually rendered (gallery
      # blocks). This deliberately excludes "Related Quest Items" icons
      # and inline ending-marker icons — those aren't part of the visual
      # walkthrough and their item images come from the API anyway.
      image_count: count_gallery_images(content_sections)
    }
  end

  def project(_), do: nil

  defp count_gallery_images(content_sections) do
    content_sections
    |> Enum.flat_map(fn section ->
      Enum.flat_map(section.blocks, fn
        %{kind: :gallery, images: images} -> images
        _ -> []
      end)
    end)
    |> length()
  end

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
        blocks: SectionParser.parse(section)
      }
    end)
    |> Enum.reject(fn s -> s.slug == "lead" or s.blocks == [] or s.heading == "" end)
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
