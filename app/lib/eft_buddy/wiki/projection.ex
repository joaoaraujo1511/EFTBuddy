defmodule EftBuddy.Wiki.Projection do
  @moduledoc """
  Pure projection of a scraped quest manifest (the `content` JSONB stored
  in `wiki_quests`) into the render-ready shape the Tasks LiveView
  consumes.

  This is the parsing core that used to live in `EftBuddy.Wiki.Loader`
  (which loaded JSON files into ETS at boot). The data now lives in the
  DB, so the GenServer/ETS/file-IO are gone, but the manifest → guide /
  objective-images / banner / karma transformation is unchanged — and it
  still operates on string-keyed maps, which is exactly what a JSONB
  column hands back.

  `project/1` is run on demand (when a quest is expanded), not for every
  row on every render, so there's no need to cache the result.
  """

  alias EftBuddy.Wiki.FileLicense

  import EftBuddy.Wiki.Markup, only: [clean_text: 1, metadata_paragraph?: 1]

  @typedoc "Render-ready projection of one quest's wiki content."
  @type quest :: %{
          task_id: String.t() | nil,
          task_name: String.t(),
          normalized_name: String.t(),
          wiki_link: String.t() | nil,
          contributors: [String.t()],
          image_uploaders: [String.t()],
          wip: boolean(),
          given_by: String.t() | nil,
          sections: [map()],
          guide: [map()],
          objectives_text: [%{index: integer(), text: String.t()}],
          objective_images: %{integer() => [map()]},
          karma_requirement: {:gte | :lte, integer()} | nil,
          banner: %{url: String.t()} | nil,
          file_count: non_neg_integer()
        }

  @doc """
  Project a (string-keyed) quest manifest into the render-ready map.

  Pre-computes the guide blocks, objectives text, per-objective images,
  scav-karma requirement and banner the LiveView reads, and keeps the
  raw `sections` for any future use.
  """
  @spec project(map()) :: quest()
  def project(manifest) when is_map(manifest) do
    sections = manifest["sections"] || []

    %{
      task_id: manifest["task_id"],
      task_name: manifest["task_name"],
      normalized_name: manifest["normalized_name"],
      # The wiki page this guide was captured from. Stored by the scraper
      # but dropped here until now, which is why nothing in the UI could
      # link back to the source — see `EftBuddyWeb.CoreComponents.source_credit/1`.
      wiki_link: manifest["wiki_link"],
      # The people who wrote this page, captured by `EftBuddy.Wiki.Contributors`.
      # Empty for manifests scraped before contributors were collected, which
      # the UI treats as "no credits captured" rather than "no contributors".
      contributors: manifest["contributors"] || [],
      # Uploaders of any image on this page that declares a licence of its own
      # (see `EftBuddy.Wiki.FileLicense.image_uploaders/1`). Almost always
      # empty. Folded into the page's contributor list, because an uploader is
      # not necessarily a page editor and would otherwise go uncredited.
      image_uploaders: FileLicense.image_uploaders(manifest),
      wip: manifest["wip"] == true,
      given_by: manifest["given_by"],
      sections: sections,
      guide: extract_guide(sections),
      objectives_text: extract_objectives_text(sections),
      objective_images: extract_objective_images(sections),
      karma_requirement: extract_karma_requirement(sections),
      banner: extract_banner(sections),
      file_count: sections |> Enum.flat_map(fn s -> s["files"] || [] end) |> length()
    }
  end

  # Section slugs that are never walkthrough content (rendered elsewhere
  # or boilerplate), so `walkthrough/1` skips them.
  @walkthrough_skip_slugs ~w(lead dialogue objectives rewards requirements initial_equipment)

  @doc """
  Every walkthrough section of a quest, parsed into render-ready blocks.

  `extract_guide/1` only covers the single section literally named
  "Guide", but many quests put their screenshots in sibling level-2
  sections instead (e.g. "Dish Served Cold" splits its guide across
  per-map "Customs" / "Shoreline" / "Woods" sections, with only a
  related-items table under "Guide"). This returns `%{heading, slug,
  level, blocks}` for each non-boilerplate section, reusing the same
  gallery/prose parser (which skips wikitables), and drops sections that
  parse to nothing — so a quest's full set of map galleries is surfaced,
  not just the one "Guide" heading.
  """
  @spec walkthrough(map()) :: [
          %{heading: String.t(), slug: String.t(), level: integer(), blocks: [map()]}
        ]
  def walkthrough(manifest) when is_map(manifest) do
    (manifest["sections"] || [])
    |> Enum.reject(fn s -> (s["slug"] || "") in @walkthrough_skip_slugs end)
    |> Enum.map(fn s ->
      blocks =
        parse_guide_wikitext(section_wikitext(s), section_level(s), build_file_queues(s["files"]))

      %{heading: s["heading"], slug: s["slug"], level: section_level(s), blocks: blocks}
    end)
    |> Enum.reject(fn s -> s.blocks == [] end)
  end

  defp section_wikitext(%{"wikitext" => w}) when is_binary(w), do: w
  defp section_wikitext(_), do: ""

  @doc """
  Parse a quest's Requirements section into a scav-karma threshold
  tuple, or nil. Exposed so the sync can persist it to a column.

    * `{:gte, n}` — needs scav karma ≥ n  ("at least +4")
    * `{:lte, n}` — needs scav karma ≤ n  ("of -1")
  """
  @spec karma_requirement(map()) :: {:gte | :lte, integer()} | nil
  def karma_requirement(manifest) when is_map(manifest) do
    extract_karma_requirement(manifest["sections"] || [])
  end

  # ── Objectives text ────────────────────────────────────────────────

  defp extract_objectives_text(sections) do
    case Enum.find(sections, fn s -> s["slug"] == "objectives" end) do
      %{"objectives" => objs} when is_list(objs) ->
        objs
        |> Enum.map(fn o -> %{index: o["index"], text: o["text"]} end)
        |> Enum.reject(fn o -> is_nil(o.text) or o.text == "" end)

      _ ->
        []
    end
  end

  # ── Banner (infobox image) ─────────────────────────────────────────

  defp extract_banner(sections) do
    sections
    |> Enum.flat_map(fn s -> s["files"] || [] end)
    |> Enum.find(fn f -> f["banner"] == true end)
    |> case do
      %{"url" => url} when is_binary(url) and url != "" -> %{url: url}
      _ -> nil
    end
  end

  # ── Scav-karma requirement ─────────────────────────────────────────

  defp extract_karma_requirement(sections) do
    sections
    |> Enum.find(fn s -> s["slug"] == "requirements" end)
    |> case do
      %{"objectives" => objs} when is_list(objs) ->
        objs
        |> Enum.map(fn o -> o["text"] end)
        |> Enum.find_value(&parse_karma_text/1)

      _ ->
        nil
    end
  end

  defp parse_karma_text(text) when is_binary(text) do
    cond do
      m = Regex.run(~r/scav karma of at least \+?(\d+)/i, text) ->
        [_, n] = m
        {:gte, String.to_integer(n)}

      m = Regex.run(~r/scav karma of -(\d+)/i, text) ->
        [_, n] = m
        {:lte, -String.to_integer(n)}

      m = Regex.run(~r/scav karma of \+?(\d+)/i, text) ->
        [_, n] = m
        {:gte, String.to_integer(n)}

      true ->
        nil
    end
  end

  defp parse_karma_text(_), do: nil

  # ── Guide block extraction ─────────────────────────────────────────

  defp extract_guide(sections) do
    case Enum.find(sections, fn s -> s["slug"] == "guide" end) do
      %{"wikitext" => wikitext} = guide when is_binary(wikitext) ->
        parse_guide_wikitext(wikitext, section_level(guide), build_file_queues(guide["files"]))

      _ ->
        []
    end
  end

  defp build_file_queues(files) when is_list(files) do
    Enum.reduce(files, %{}, fn file, acc ->
      case normalize_wiki_filename(file["wiki_filename"]) do
        "" -> acc
        key -> Map.update(acc, key, [file], fn fs -> fs ++ [file] end)
      end
    end)
  end

  defp build_file_queues(_), do: %{}

  defp parse_guide_wikitext(wikitext, guide_level, queues) do
    %{blocks: [], prose: [], gallery: [], mode: :normal, queues: queues, guide_level: guide_level}
    |> then(fn acc ->
      wikitext
      |> String.split(~r/\r?\n/)
      |> Enum.reduce(acc, &parse_guide_line/2)
    end)
    |> flush_prose()
    |> close_gallery()
    |> Map.fetch!(:blocks)
    |> Enum.reverse()
  end

  defp parse_guide_line(line, %{mode: :table} = acc) do
    if String.starts_with?(String.trim_leading(line), "|}") do
      %{acc | mode: :normal}
    else
      acc
    end
  end

  defp parse_guide_line(line, %{mode: :gallery} = acc) do
    trimmed = String.trim(line)

    if String.contains?(trimmed, "</gallery>") do
      before = trimmed |> String.split("</gallery>") |> List.first() |> String.trim()
      acc = if before == "", do: acc, else: add_gallery_image(acc, before)
      acc |> close_gallery() |> Map.put(:mode, :normal)
    else
      add_gallery_image(acc, trimmed)
    end
  end

  defp parse_guide_line(line, acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        flush_prose(acc)

      String.starts_with?(trimmed, "{|") ->
        acc |> flush_prose() |> Map.put(:mode, :table)

      String.contains?(trimmed, "<gallery") ->
        acc |> flush_prose() |> Map.merge(%{mode: :gallery, gallery: []})

      (refs = standalone_file_refs(trimmed)) != [] ->
        {images, acc} = resolve_files(flush_prose(acc), refs)
        if images == [], do: acc, else: push_block(acc, %{kind: :gallery, images: images})

      markup_line?(trimmed) ->
        acc

      interlanguage_links_only?(trimmed) ->
        # Bottom-of-page interlanguage links (`[[FR:Swag - Partie 1]]`,
        # `[[ru:Обновка. Часть 1]]`, …) live in the page's last `==`-level
        # section, which for many quest pages is the Guide. They're
        # navigation metadata, never guide prose, so drop them before they
        # can be accumulated into a stray paragraph.
        acc

      true ->
        case guide_heading(trimmed) do
          {level, text} ->
            acc = flush_prose(acc)

            if level > acc.guide_level and String.downcase(text) != "guide" do
              push_block(acc, %{kind: :heading, level: level, text: text})
            else
              acc
            end

          nil ->
            %{acc | prose: [trimmed | acc.prose]}
        end
    end
  end

  defp guide_heading(line) do
    case Regex.run(~r/^(={2,})\s*(.+?)\s*={2,}\s*$/, line) do
      [_, equals, text] -> {String.length(equals), clean_text(text)}
      _ -> nil
    end
  end

  defp standalone_file_refs(line) do
    ~r/\[\[(?:File|Image):([^\|\]]+)/i
    |> Regex.scan(line, capture: :all_but_first)
    |> List.flatten()
  end

  defp markup_line?(trimmed), do: Regex.match?(~r/^[|!{}<*:;#]/, trimmed)

  # A line consisting solely of interlanguage links — `[[xx:Title]]` where
  # `xx` is a 2–3 letter language code. Distinct from namespaced links like
  # `[[File:…]]` / `[[Category:…]]` (4+ letter prefixes) and plain content
  # links (no colon), so legitimate guide links are never dropped.
  defp interlanguage_links_only?(line) do
    Regex.match?(~r/^(?:\[\[[a-z]{2,3}:[^\]]*\]\]\s*)+$/i, line)
  end

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
    case Map.get(queues, normalize_wiki_filename(name)) do
      [file | rest] -> {file, Map.put(queues, normalize_wiki_filename(name), rest)}
      _ -> {nil, queues}
    end
  end

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

  defp close_gallery(%{gallery: []} = acc), do: %{acc | gallery: []}

  defp close_gallery(acc) do
    block = %{kind: :gallery, images: Enum.reverse(acc.gallery)}
    %{push_block(acc, block) | gallery: []}
  end

  defp push_block(acc, block), do: %{acc | blocks: [block | acc.blocks]}

  defp section_level(%{"level" => level}) when is_integer(level), do: level

  defp section_level(%{"level" => level}) when is_binary(level) do
    case Integer.parse(level) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp section_level(_), do: 0

  defp normalize_wiki_filename(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp normalize_wiki_filename(_), do: ""

  # ── Per-objective image map ────────────────────────────────────────

  defp extract_objective_images(sections) do
    case Enum.find(sections, fn s -> s["slug"] == "objectives" end) do
      %{"files" => files} when is_list(files) ->
        files
        |> Enum.filter(fn f -> is_integer(f["objective"]) end)
        |> Enum.group_by(fn f -> f["objective"] end)

      _ ->
        %{}
    end
  end
end
