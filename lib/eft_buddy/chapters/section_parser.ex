defmodule EftBuddy.Chapters.SectionParser do
  @moduledoc """
  Turns a single storyline-chapter section's raw `wikitext` into an
  ordered list of render-ready blocks for the storyline detail page.

  Storyline chapters are wiki-only editorial pages whose walkthroughs
  are far richer than the per-quest Guide section: a leaf section mixes
  bulleted objective lists, prose paragraphs, sub-headings, and
  `<gallery>` screenshot rows, all of which carry meaning *in document
  order*. The dump's structured `objectives` array only captures the
  bullet lines (it drops prose, headings and gallery placement), so we
  re-walk the retained `wikitext` here to reproduce the page faithfully.

  This is deliberately a self-contained sibling of
  `EftBuddy.Wiki.Projection`'s quest-guide parser rather than a shared
  dependency: the quest parser is tuned for a single flat "Guide"
  section and intentionally *discards* bullet lists, whereas chapters
  need those bullets kept and nested. Keeping the two apart means the
  production quest path is untouched by storyline changes.

  ## Block shapes

    * `%{kind: :heading, level: 3..6, text: String.t()}` — a sub-heading
      *deeper* than the section's own heading (the section heading
      itself is rendered by the caller and skipped here).
    * `%{kind: :prose, text: String.t()}` — a description paragraph.
    * `%{kind: :list, ordered: boolean(), items: [%{level, text}]}` — a
      run of bullet/numbered lines; `level` is the marker depth so the
      caller can indent nested steps.
    * `%{kind: :gallery, images: [%{file: map(), caption: String.t() | nil}]}` —
      a row of screenshots, each resolved to a dumped CDN image.

  Images are matched to the section's dumped `files` via a per-filename
  FIFO queue (the Nth reference to a filename maps to the Nth dumped
  copy), exactly like the quest guide parser, so a screenshot reused
  under several headings still resolves to the right entry.
  """

  import EftBuddy.Wiki.Markup, only: [clean_text: 1, strip_inline_file_refs: 1]

  @type block ::
          %{kind: :heading, level: pos_integer(), text: String.t()}
          | %{kind: :prose, text: String.t()}
          | %{
              kind: :list,
              ordered: boolean(),
              items: [%{level: pos_integer(), text: String.t()}]
            }
          | %{kind: :gallery, images: [%{file: map(), caption: String.t() | nil}]}
          | %{
              kind: :items,
              items: [
                %{
                  name: String.t(),
                  page: String.t(),
                  amount: String.t() | nil,
                  requirement: String.t() | nil,
                  found_in_raid: boolean() | nil
                }
              ]
            }

  @doc """
  Parse one section map (`%{"wikitext" => ..., "level" => ..., "files" => ...}`)
  into an ordered list of blocks. Returns `[]` for the lead/infobox
  section and for sections whose wikitext yields no renderable content.
  """
  @spec parse(map()) :: [block()]
  def parse(%{"slug" => "lead"}), do: []

  def parse(%{"wikitext" => wikitext} = section) when is_binary(wikitext) do
    %{
      blocks: [],
      prose: [],
      list: [],
      list_ordered: false,
      gallery: [],
      table: [],
      mode: :normal,
      done: false,
      stop_subsections: page_own_section?(section),
      queues: build_file_queues(section["files"]),
      section_level: section_level(section)
    }
    |> then(fn acc ->
      wikitext
      |> unwrap_quote_templates()
      |> String.split(~r/\r?\n/)
      |> Enum.reduce(acc, &parse_line/2)
    end)
    |> flush_all()
    |> close_gallery()
    |> Map.fetch!(:blocks)
    |> Enum.reverse()
  end

  def parse(_), do: []

  # `{{quote|<text>|<author>}}` wraps an in-universe blurb (e.g. each
  # ending's description on the Endings page). The generic template
  # stripping in `clean_text/1` would delete it entirely, so unwrap it
  # up front — keep only the first positional arg (the quote body, drop
  # any author/source) — so it survives as ordinary prose. Done before
  # line splitting so a quote that opens a line isn't mistaken for
  # skippable `{{`-markup.
  defp unwrap_quote_templates(wikitext) do
    Regex.replace(~r/\{\{\s*quote\s*\|(.+?)\}\}/is, wikitext, fn _, inner ->
      inner |> String.split("|") |> List.first() |> String.trim()
    end)
  end

  # Whether to stop parsing at the first sub-heading. MediaWiki returns a
  # heading section's wikitext INCLUDING all of its deeper subsections,
  # and the dump stores each of those subsections as its own section too
  # — so for a page-own section (integer index) we must stop at the first
  # sub-heading or we'd render every child's content twice (once here,
  # once in the child section). Transcluded guide templates (`tmpl:`
  # index) carry their subsections inline and are NOT dumped separately,
  # so those are parsed in full.
  defp page_own_section?(section) do
    not (section["index"] |> to_string() |> String.starts_with?("tmpl:"))
  end

  # ── Line dispatch ──────────────────────────────────────────────────

  # Once we've hit the first sub-heading of a page-own section, the rest
  # of the wikitext belongs to separately-dumped child sections; ignore
  # it so content isn't rendered twice.
  defp parse_line(_line, %{done: true} = acc), do: acc

  # Inside a wikitable: buffer every line until the closing `|}`, then
  # `finalize_table/1` decides what to do with it. A "Related Quest
  # Items" table becomes an `:items` block (rendered in place, in wiki
  # order, with links into the Items tab); any other table (decorative
  # ending banners, stray layout tables) is discarded.
  defp parse_line(line, %{mode: :table} = acc) do
    if String.starts_with?(String.trim_leading(line), "|}") do
      acc |> finalize_table() |> Map.merge(%{mode: :normal, table: []})
    else
      %{acc | table: [line | acc.table]}
    end
  end

  # Inside a `<gallery>`: each line is a `File:Name|caption` entry until
  # the closing `</gallery>` (which may share a line with the last entry
  # or an `</li>` wrapper).
  defp parse_line(line, %{mode: :gallery} = acc) do
    trimmed = String.trim(line)

    if String.contains?(trimmed, "</gallery>") do
      before = trimmed |> String.split("</gallery>") |> List.first() |> String.trim()
      acc = if before == "", do: acc, else: add_gallery_image(acc, before)
      acc |> close_gallery() |> Map.put(:mode, :normal)
    else
      add_gallery_image(acc, trimmed)
    end
  end

  defp parse_line(line, acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        flush_all(acc)

      String.starts_with?(trimmed, "{|") ->
        acc |> flush_all() |> Map.merge(%{mode: :table, table: []})

      String.contains?(trimmed, "<gallery") ->
        acc |> flush_all() |> Map.merge(%{mode: :gallery, gallery: []})

      match = Regex.run(~r/^(={2,})\s*(.+?)\s*={2,}\s*$/, trimmed) ->
        handle_heading(acc, match)

      match = Regex.run(~r/^([*#]+)\s*(.*)$/, trimmed) ->
        handle_list_item(acc, match)

      (refs = standalone_file_refs(trimmed)) != [] ->
        {images, acc} = resolve_files(flush_all(acc), refs)
        if images == [], do: acc, else: push_block(acc, %{kind: :gallery, images: images})

      markup_line?(trimmed) ->
        acc

      true ->
        %{acc | prose: [trimmed | acc.prose]}
    end
  end

  # Only emit sub-headings deeper than the section's own heading; the
  # section heading itself is rendered by the caller. Levels are clamped
  # into the 3..6 range the heading styling understands.
  defp handle_heading(acc, [_, equals, text]) do
    acc = flush_all(acc)
    level = String.length(equals)
    cleaned = clean_text(text)

    cond do
      level <= acc.section_level or cleaned == "" ->
        acc

      acc.stop_subsections ->
        # First sub-heading of a page-own section — its content (and
        # everything after) is a separately-dumped child section.
        %{acc | done: true}

      true ->
        push_block(acc, %{kind: :heading, level: clamp_heading(level), text: cleaned})
    end
  end

  defp clamp_heading(level) when level < 3, do: 3
  defp clamp_heading(level) when level > 6, do: 6
  defp clamp_heading(level), do: level

  # Accumulate a bullet/numbered line into the pending list. Prose is
  # flushed first so a list never swallows a preceding paragraph; the
  # gallery (if any) is also closed. The list's `ordered?` is decided by
  # the first marker char seen.
  defp handle_list_item(acc, [_, markers, text]) do
    case clean_text(strip_inline_file_refs(text)) do
      "" ->
        acc

      cleaned ->
        acc = acc |> flush_prose() |> close_gallery()
        item = %{level: String.length(markers), text: cleaned}

        # The first marker in a run decides whether it renders ordered
        # (`#`) or unordered (`*`); subsequent lines keep that choice.
        ordered? =
          if acc.list == [],
            do: String.starts_with?(markers, "#"),
            else: Map.get(acc, :list_ordered, false)

        %{acc | list: [item | acc.list], list_ordered: ordered?}
    end
  end

  # ── Gallery / file resolution ──────────────────────────────────────

  defp add_gallery_image(acc, segment) do
    case Regex.run(~r/^(?:File|Image):([^\|\]\n]+?)\s*(?:\|\s*(.*?))?\s*$/i, segment) do
      [_, name] -> add_resolved_image(acc, name, "")
      [_, name, caption] -> add_resolved_image(acc, name, caption)
      _ -> acc
    end
  end

  defp add_resolved_image(acc, name, caption) do
    case pop_file(acc.queues, name) do
      {nil, _queues} ->
        acc

      {file, queues} ->
        image = %{file: file, caption: resolve_caption(caption, file)}
        %{acc | gallery: [image | acc.gallery], queues: queues}
    end
  end

  defp resolve_files(acc, names) do
    {images, queues} =
      Enum.reduce(names, {[], acc.queues}, fn name, {imgs, q} ->
        case pop_file(q, name) do
          {nil, q2} -> {imgs, q2}
          {file, q2} -> {[%{file: file, caption: resolve_caption("", file)} | imgs], q2}
        end
      end)

    {Enum.reverse(images), %{acc | queues: queues}}
  end

  defp pop_file(queues, name) do
    key = normalize_wiki_filename(name)

    case Map.get(queues, key) do
      [file | rest] -> {file, Map.put(queues, key, rest)}
      _ -> {nil, queues}
    end
  end

  # FIFO queue of dumped files per normalized filename, in the document
  # order they appear in the section's `files`. Banner files are excluded
  # — the banner is rendered separately on the detail page header.
  defp build_file_queues(files) when is_list(files) do
    files
    |> Enum.reject(fn f -> f["banner"] == true end)
    |> Enum.reduce(%{}, fn file, acc ->
      case normalize_wiki_filename(file["wiki_filename"]) do
        "" -> acc
        key -> Map.update(acc, key, [file], fn fs -> fs ++ [file] end)
      end
    end)
  end

  defp build_file_queues(_), do: %{}

  defp resolve_caption(caption, file) do
    case clean_text(caption) do
      "" ->
        case file["caption"] do
          c when is_binary(c) and c != "" -> String.trim(c)
          _ -> nil
        end

      cleaned ->
        cleaned
    end
  end

  # `[[File:Foo.png|…]]` references on a normal (non-gallery) line.
  defp standalone_file_refs(line) do
    ~r/\[\[(?:File|Image):([^\|\]]+)/i
    |> Regex.scan(line, capture: :all_but_first)
    |> List.flatten()
  end

  # ── Flushing pending accumulators ──────────────────────────────────

  defp flush_all(acc), do: acc |> flush_prose() |> flush_list()

  defp flush_prose(%{prose: []} = acc), do: acc

  defp flush_prose(acc) do
    text = acc.prose |> Enum.reverse() |> Enum.join(" ") |> clean_text()
    acc = %{acc | prose: []}

    if text != "" and not metadata_paragraph?(text) do
      push_block(acc, %{kind: :prose, text: text})
    else
      acc
    end
  end

  defp flush_list(%{list: []} = acc), do: acc

  defp flush_list(acc) do
    items = Enum.reverse(acc.list)
    block = %{kind: :list, ordered: Map.get(acc, :list_ordered, false), items: items}
    %{push_block(acc, block) | list: [], list_ordered: false}
  end

  defp close_gallery(%{gallery: []} = acc), do: %{acc | gallery: []}

  defp close_gallery(acc) do
    block = %{kind: :gallery, images: Enum.reverse(acc.gallery)}
    %{push_block(acc, block) | gallery: []}
  end

  defp push_block(acc, block), do: %{acc | blocks: [block | acc.blocks]}

  # ── Wikitable parsing ("Related Quest Items") ──────────────────────

  # Turn a buffered wikitable into an `:items` block if it's a "Related
  # Quest Items" table, else leave the accumulator untouched (the table
  # is decorative / unrelated and gets dropped). Items keep their wiki
  # row order so the rendered list mirrors the official page.
  defp finalize_table(acc) do
    rows = acc.table |> Enum.reverse() |> table_rows()

    case Enum.find_index(rows, &items_header?/1) do
      nil ->
        acc

      header_idx ->
        cols = column_map(Enum.at(rows, header_idx))

        if Map.has_key?(cols, :name) do
          {items, queues} =
            rows |> Enum.drop(header_idx + 1) |> build_item_rows(cols, acc.queues)

          acc = %{acc | queues: queues}
          if items == [], do: acc, else: push_block(acc, %{kind: :items, items: items})
        else
          acc
        end
    end
  end

  # Split buffered table lines into rows (separated by `|-`), each row a
  # list of cell strings (one cell per `!`/`|` line; cell attributes like
  # `colspan="5"|` stripped).
  defp table_rows(lines) do
    {rows, current} =
      Enum.reduce(lines, {[], []}, fn line, {rows, current} ->
        if String.starts_with?(String.trim_leading(line), "|-") do
          {[Enum.reverse(current) | rows], []}
        else
          {rows, [line | current]}
        end
      end)

    [Enum.reverse(current) | rows]
    |> Enum.reverse()
    |> Enum.map(&row_cells/1)
    |> Enum.reject(&(&1 == []))
  end

  defp row_cells(lines) do
    lines
    |> Enum.map(&String.trim_leading/1)
    |> Enum.filter(fn t -> String.starts_with?(t, "!") or String.starts_with?(t, "|") end)
    |> Enum.map(fn t ->
      t |> String.replace_prefix("!", "") |> String.replace_prefix("|", "") |> cell_content()
    end)
  end

  # Strip a leading cell-attribute segment (`colspan="5" |`, `style=… |`)
  # from a cell, taking care never to mistake a `[[Page|Label]]` pipe for
  # an attribute separator.
  defp cell_content(raw) do
    raw = String.trim(raw)

    case find_attr_pipe(raw, 0, 0) do
      nil ->
        raw

      idx ->
        prefix = binary_part(raw, 0, idx)

        if String.contains?(prefix, "=") do
          raw |> binary_part(idx + 1, byte_size(raw) - idx - 1) |> String.trim()
        else
          raw
        end
    end
  end

  # Byte offset of the first `|` at wikilink-bracket depth 0, or nil.
  defp find_attr_pipe(<<>>, _pos, _depth), do: nil

  defp find_attr_pipe(<<?[, rest::binary>>, pos, depth),
    do: find_attr_pipe(rest, pos + 1, depth + 1)

  defp find_attr_pipe(<<?], rest::binary>>, pos, depth),
    do: find_attr_pipe(rest, pos + 1, max(depth - 1, 0))

  defp find_attr_pipe(<<?|, _::binary>>, pos, 0), do: pos
  defp find_attr_pipe(<<_, rest::binary>>, pos, depth), do: find_attr_pipe(rest, pos + 1, depth)

  defp items_header?(cells) do
    Enum.any?(cells, fn c -> String.contains?(String.downcase(c), "item name") end)
  end

  # Map the header cells onto the column indices we care about. First
  # match wins, so the specific "item name" is checked before the bare
  # "name"/"icon" substrings.
  defp column_map(header) do
    header
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {cell, idx}, acc ->
      c = cell |> clean_text() |> String.downcase()

      cond do
        String.contains?(c, "item name") -> Map.put_new(acc, :name, idx)
        c == "name" -> Map.put_new(acc, :name, idx)
        String.contains?(c, "icon") -> Map.put_new(acc, :icon, idx)
        String.contains?(c, "amount") -> Map.put_new(acc, :amount, idx)
        String.contains?(c, "requirement") -> Map.put_new(acc, :requirement, idx)
        String.contains?(c, "notes") -> Map.put_new(acc, :requirement, idx)
        String.contains?(c, "find in raid") -> Map.put_new(acc, :fir, idx)
        String.contains?(c, "found in raid") -> Map.put_new(acc, :fir, idx)
        true -> acc
      end
    end)
  end

  defp build_item_rows(rows, cols, queues) do
    {items, queues} =
      Enum.reduce(rows, {[], queues}, fn cells, {acc, q} ->
        case build_item(cells, cols, q) do
          {nil, q2} -> {acc, q2}
          {item, q2} -> {[item | acc], q2}
        end
      end)

    {Enum.reverse(items), queues}
  end

  defp build_item(cells, cols, queues) do
    case parse_item_name(cell_at(cells, cols[:name])) do
      nil ->
        {nil, queues}

      {page, display} ->
        # No icon resolution here: item images come from the tarkov.dev
        # API at render time (resolved by name against the DB), so a
        # wiki entry that isn't a real item carries no image at all.
        item = %{
          name: display,
          page: page,
          amount: cells |> cell_at(cols[:amount]) |> clean_text() |> blank_to_nil(),
          requirement: cells |> cell_at(cols[:requirement]) |> clean_text() |> blank_to_nil(),
          found_in_raid: cells |> cell_at(cols[:fir]) |> parse_fir()
        }

        {item, queues}
    end
  end

  defp cell_at(_cells, nil), do: nil
  defp cell_at(cells, idx), do: Enum.at(cells, idx)

  defp parse_item_name(nil), do: nil

  defp parse_item_name(cell) do
    case Regex.run(~r/\[\[\s*([^\]\|]+?)\s*(?:\|\s*([^\]]+?))?\s*\]\]/, cell) do
      [_, page] ->
        {String.trim(page), clean_text(page)}

      [_, page, display] ->
        {String.trim(page), clean_text(display)}

      _ ->
        case clean_text(cell) do
          "" -> nil
          text -> {text, text}
        end
    end
  end

  defp parse_fir(nil), do: nil

  defp parse_fir(cell) do
    case cell |> clean_text() |> String.downcase() do
      "yes" -> true
      "no" -> false
      _ -> nil
    end
  end

  defp blank_to_nil(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  # ── Text helpers ───────────────────────────────────────────────────

  # Structural markup lines (table cells, stray html, definition lists)
  # that should never leak into prose. Headings, tables, galleries and
  # list items are handled by earlier clauses, so this is the leftover
  # catch. `*`/`#` are intentionally absent — bullet lines are list items.
  defp markup_line?(trimmed), do: Regex.match?(~r/^[|!{}<:;]/, trimmed)

  # Drop residual category links / interwiki references that survive the
  # markup strip (e.g. "Category:Quests", "cs:Zlatý lup", "FR:Swag").
  # The interwiki prefix is matched case-insensitively because MediaWiki
  # language codes appear as both `cs:` and `FR:`.
  defp metadata_paragraph?(p) do
    String.starts_with?(p, "Category:") or Regex.match?(~r/^[a-z]{2,3}:\S/iu, p)
  end

  defp section_level(%{"level" => level}) when is_integer(level), do: level

  defp section_level(%{"level" => level}) when is_binary(level) do
    case Integer.parse(level) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp section_level(_), do: 0

  # MediaWiki treats the first filename letter case-insensitively and
  # spaces / underscores as equivalent. Normalize both the reference and
  # the manifest's `wiki_filename` the same way so they always match.
  defp normalize_wiki_filename(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp normalize_wiki_filename(_), do: ""
end
