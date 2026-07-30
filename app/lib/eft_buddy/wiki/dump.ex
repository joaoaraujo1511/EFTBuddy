defmodule EftBuddy.Wiki.Dump do
  @moduledoc """
  Pure, side-effect-free core of the quest-page wiki pipeline.

  The impure runner — `EftBuddy.Wiki.Sync` — injects the MediaWiki API
  calls (`:fetch`, `:resolve`), the `Category:Quests` enumeration, the
  DB read that builds the match index, and the row upsert (`:write`) —
  so everything here is deterministic and unit-testable.

  Mirror of `EftBuddy.Chapters.Dump`. The manifest this assembles
  retains the raw per-section `wikitext` so `EftBuddy.Wiki.Projection`
  can re-derive the guide/objective projections from the stored
  `wiki_quests.content` without re-hitting the wiki.
  """

  @image_modifiers ~w(thumb thumbnail frame frameless border none left right center)
  @image_modifier_kv_keys ~w(link alt class lang page start end thumbtime upright)

  alias EftBuddy.Wiki.Slug

  # Low-level wikitext primitives and inline-file stripping are shared
  # with the storyline pipeline via EftBuddy.Wiki.Markup so the two
  # dumps parse links identically.
  import EftBuddy.Wiki.Markup,
    only: [
      strip_html_comments: 1,
      strip_nowiki: 1,
      strip_inline_file_refs: 1,
      scan_wikilink: 2,
      split_pipes_depth_aware: 1
    ]

  # ── Quest set ───────────────────────────────────────────────────────

  @doc """
  Build the lookup index the quest pipeline matches wiki pages against,
  from `[%{id, name, normalized_name}]` DB rows.

  Each DB task is indexed under TWO keys, both derived by *our* slugger
  (`normalize_name/1`): the API's `normalized_name`, and
  `normalize_name(name)`.

  Indexing the name slug is what makes matching robust. A wiki page
  title *is* the quest name, so it slugs identically to the API `name`
  here — even when tarkov.dev's own `normalizedName` diverges. Observed
  divergences (all matched correctly via the name slug):

    * apostrophes deleted, not dashed — "Developer's Secrets - Part 1"
      → API `developers-secrets-part-1`, ours `developer-s-...`
    * faction / edition / dedup suffixes that live ONLY on the slug —
      "Drip-Out - Part 1" → `drip-out-part-1-bear` / `-usec`,
      "Battery Change" → `battery-change-2`
    * number joins — "Hindsight 20/20" → `hindsight-2020`

  Two passes so the canonical `normalized_name` keys always win over a
  `name`-slug collision (faction/edition variants share a display name);
  within each pass `Map.put_new/3` keeps the first row, so pre-sorting
  rows by `normalized_name` makes the result deterministic.
  """
  def build_db_index(rows) when is_list(rows) do
    base =
      Enum.reduce(rows, %{}, fn %{id: id, normalized_name: nn}, acc ->
        Map.put_new(acc, nn, %{id: id, normalized_name: nn})
      end)

    Enum.reduce(rows, base, fn %{id: id, name: name, normalized_name: nn}, acc ->
      name_slug = normalize_name(name)
      Map.put_new(acc, name_slug, %{id: id, normalized_name: variant_base(name_slug, nn)})
    end)
  end

  # The slug a matched wiki page should adopt for a NAME-slug match.
  #
  # A faction-locked quest's API `normalizedName` is its display-name slug
  # with a `-bear` / `-usec` tail appended for disambiguation, but its
  # single wiki page is titled without it. When two faction variants share
  # one display name (e.g. "Drip-Out - Part 1", "Textile - Part 1"), the
  # shared name-slug key would otherwise adopt whichever variant sorts
  # first (`-bear`), leaving the OTHER faction's task unable to find the
  # wiki row — so its guide/images silently vanish. Keying on the
  # suffix-less base (which equals the wiki page's own slug, and which
  # BOTH variants' name slug resolves to) fixes that. We only strip when
  # the tail is EXACTLY the variant marker, so a quest genuinely named
  # "… Bear" (whose slug already equals its name slug) is left intact.
  defp variant_base(name_slug, nn) do
    if nn in [name_slug <> "-bear", name_slug <> "-usec"], do: name_slug, else: nn
  end

  @doc """
  Build the quest struct the pipeline operates on from a wiki page title
  and a DB index (see `build_db_index/1`).

  A quest page title on this wiki *is* the quest name, so it's used for
  both. The title is slugged with `normalize_name/1` and looked up in
  `db_index`:

    * **matched** — the quest already exists in the DB (synced from
      tarkov.dev). `wip` is `false`, and the manifest adopts the DB's
      `normalized_name` and `id` so the loader's enrichment lookup and
      the Tasks-page dedup both key on the same slug as the DB task.
    * **unmatched** — genuinely wiki-only (tarkov.dev hasn't synced it
      yet). `wip` is `true` and the wiki-derived slug is used.
  """
  def build_quest(title, db_index) when is_map(db_index) do
    wiki_link = "https://escapefromtarkov.fandom.com/wiki/" <> String.replace(title, " ", "_")
    name = strip_disambiguator(title)

    case Map.get(db_index, normalize_name(name)) do
      %{id: id, normalized_name: normalized_name} ->
        %{
          id: id,
          name: name,
          normalized_name: normalized_name,
          wiki_title: title,
          wiki_link: wiki_link,
          wip: false
        }

      nil ->
        %{
          id: nil,
          name: name,
          normalized_name: normalize_name(name),
          wiki_title: title,
          wiki_link: wiki_link,
          wip: true
        }
    end
  end

  # The wiki disambiguates a quest page that shares its title with a
  # map/location/skill by appending " (quest)" (e.g. "Reserve (quest)",
  # "Immunity (quest)", "Bloodhounds (quest)"). That suffix is a wiki
  # artifact, never part of the quest's real name, so strip it before
  # matching/naming — otherwise the page's slug ("reserve-quest") fails to
  # match its API task ("reserve") and the quest lands as a duplicate WIP
  # page that steals the guide from the real task. The ORIGINAL title is
  # still kept as `wiki_title`/`wiki_link` so the page is fetched/linked
  # correctly.
  defp strip_disambiguator(title) do
    title
    |> String.replace(~r/\s*\(quest\)\s*$/i, "")
    |> String.trim()
  end

  @doc "Lowercase, dash-joined, transliteration-aware slug derived from a name."
  defdelegate normalize_name(name), to: Slug

  # ── Blacklist ───────────────────────────────────────────────────────
  #
  # Two content-based exclusions decided from the lead section alone, so
  # the impure runner can drop a page *before* fetching its remaining
  # sections and resolving its images — neither ever writes a
  # `wiki_quests` row (so they vanish from the Tasks-tab WIP list), and
  # skipping them shortens the run.

  # The `{{Historical content}}` notice the wiki stamps on pages for
  # content that "was removed or replaced" (it renders the lead-section
  # banner and adds the page to `Category:Historical content`). MediaWiki
  # treats a template name's spaces and underscores interchangeably, so
  # `historical[\s_]+content` matches `{{Historical content}}`,
  # `{{Historical_content}}` and `{{Historical  content}}` alike; the
  # trailing `[|}]` allows a future `{{Historical content|reason=…}}`.
  @historical_content_template ~r/\{\{\s*historical[\s_]+content\s*[|}]/i

  # Quests whose infobox `given by` is the trader Ref. He only brokers
  # Arena item/currency transfers and GP-coin barters, so his "quests"
  # aren't real Tasks and only clutter WIP. Matched on a word boundary so
  # a giver name merely *containing* "ref" (e.g. "Referee") isn't caught,
  # and "Ref" listed among several givers ("Skier or Ref") still is.
  @blacklisted_giver ~r/\bref\b/i

  @doc """
  Decide whether a quest page should be dropped from the scrape, based on
  its lead-section wikitext. Returns the reason or `nil`.

    * `:historical` — the page carries the `{{Historical content}}`
      notice ("This page describes content that was removed or
      replaced."), i.e. a quest cut from the live game.
    * `:ref` — the quest's infobox `given by` is the trader Ref.

  HTML comments are stripped first, so a commented-out
  `<!-- {{Historical content}} -->` / `<!-- |given by =[[Ref]] -->` never
  trips the blacklist (which would wrongly prune a live quest's row).
  Both signals are surfaced from the lead section alone, so the impure
  runner can short-circuit before fetching the rest of the page; a
  `:historical` match takes precedence over the giver check.
  """
  @spec blacklist_reason(String.t() | nil) :: :historical | :ref | nil
  def blacklist_reason(lead_wikitext) when is_binary(lead_wikitext) do
    cleaned = strip_html_comments(lead_wikitext)

    cond do
      Regex.match?(@historical_content_template, cleaned) -> :historical
      given_by_blacklisted?(cleaned) -> :ref
      true -> nil
    end
  end

  def blacklist_reason(_), do: nil

  defp given_by_blacklisted?(wikitext) do
    case parse_given_by(wikitext) do
      nil -> false
      given -> Regex.match?(@blacklisted_giver, given)
    end
  end

  # Pages that sit in `Category:Quests` but aren't real quests — the
  # category's own index/landing articles ("Quest", "Quests"). They have
  # no infobox to match and only clutter WIP, so they're dropped during
  # enumeration (pre-fetch), before a row is ever built for them.
  @non_quest_titles MapSet.new(["quest", "quests"])

  @doc """
  False for `Category:Quests` member pages that aren't actually quests
  (e.g. the "Quest" index article), so the sync can drop them before
  fetching anything.
  """
  @spec quest_title?(String.t()) :: boolean()
  def quest_title?(title) when is_binary(title) do
    not MapSet.member?(@non_quest_titles, title |> String.trim() |> String.downcase())
  end

  def quest_title?(_), do: false

  # ── Orchestration ──────────────────────────────────────────────────

  @doc """
  Process every quest, isolating failures so one bad page never aborts
  the run.

  Required injected functions (keep this module pure):

    * `:fetch`   — `quest -> {:ok, [%{index, heading, level, wikitext}]} | {:skip, reason} | {:error, reason}`
      (the section list including the synthesized lead, each with its
      raw wikitext). `{:skip, reason}` drops the quest without writing a
      row — used to blacklist Ref / `{{Historical content}}` pages from
      the lead section before the rest is fetched.
    * `:resolve` — `[file_title] -> %{file_title => imageinfo}` (CDN
      url/size/mime keyed by the `"File:"`-prefixed title)
    * `:write`   — `(quest, manifest) -> :ok | {:error, reason}`

  Options:

    * `:dry_run`     — skip image resolution (the manifest is still
      written, with `nil` urls — matching the script's historical
      behaviour)
    * `:on_progress` — `(quest, index, total) -> any`, called before
      each quest (for logging)
    * `:on_result`   — `(quest, {:ok, resolved_count} | {:skip, reason} | {:error, reason}) -> any`,
      called after each quest (for logging)

  Returns `%{failures: [%{slug, reason}], skipped: [%{slug, reason}],
  summary: %{processed, failed, skipped, resolved}}`.
  """
  def run(quests, opts) when is_list(quests) do
    fetch = Keyword.fetch!(opts, :fetch)
    resolve = Keyword.fetch!(opts, :resolve)
    write = Keyword.fetch!(opts, :write)
    dry_run? = !!Keyword.get(opts, :dry_run, false)
    on_progress = Keyword.get(opts, :on_progress, fn _quest, _idx, _total -> :ok end)
    on_result = Keyword.get(opts, :on_result, fn _quest, _result -> :ok end)
    total = length(quests)

    {failures, processed, resolved, skipped} =
      quests
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0, 0, []}, fn {quest, idx}, {failures, processed, resolved, skipped} ->
        on_progress.(quest, idx, total)
        result = process_one(quest, fetch, resolve, write, dry_run?)
        on_result.(quest, result)

        case result do
          {:ok, count} ->
            {failures, processed + 1, resolved + count, skipped}

          {:skip, reason} ->
            {failures, processed, resolved,
             [%{slug: quest.normalized_name, reason: reason} | skipped]}

          {:error, reason} ->
            {[%{slug: quest.normalized_name, reason: reason} | failures], processed, resolved,
             skipped}
        end
      end)

    %{
      failures: Enum.reverse(failures),
      skipped: Enum.reverse(skipped),
      summary: %{
        processed: processed,
        failed: length(failures),
        skipped: length(skipped),
        resolved: resolved
      }
    }
  end

  defp process_one(quest, fetch, resolve, write, dry_run?) do
    case fetch.(quest) do
      # The fetch decided this page should not be written at all (e.g. a
      # blacklisted Ref / historical-content quest). Nothing to parse,
      # resolve or upsert; the runner records it as skipped.
      {:skip, reason} ->
        {:skip, reason}

      {:ok, raw_sections} ->
        parsed =
          raw_sections
          |> Enum.map(&parse_raw_section(&1, quest.wip))
          |> suppress_guide_images(quest)

        wiki_titles =
          parsed |> Enum.flat_map(& &1.files) |> Enum.map(&("File:" <> &1.file)) |> Enum.uniq()

        info_map =
          if dry_run? or wiki_titles == [], do: %{}, else: resolve.(wiki_titles)

        manifest = build_manifest(quest, quest.wiki_title, parsed, info_map)

        # NB: unlike the chapter dump, a quest dry-run still writes the
        # manifest (only image resolution is skipped) — preserving this
        # script's historical behaviour.
        case write.(quest, manifest) do
          :ok -> {:ok, map_size(info_map)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse one fetched section into the `%{section, objectives, files,
  # wikitext}` shape `build_manifest/4` expects. The quest banner lives
  # in the infobox `image=` param; it's only injected for WIP quests
  # (DB-matched quests already serve their banner from the API).
  defp parse_raw_section(%{index: index, heading: heading, level: level, wikitext: wikitext}, wip) do
    parse_result =
      %{index: index, heading: heading, level: level}
      |> parse_section(wikitext, not wip)

    parse_result =
      if index == "0" and wip,
        do: add_banner_file(parse_result, wikitext),
        else: parse_result

    Map.put(parse_result, :wikitext, wikitext)
  end

  # ── Erroneous-image suppression ─────────────────────────────────────
  #
  # A few quest pages carry an image the official wiki editors added by
  # mistake. We keep the guide *text* but drop the stray image. Keyed by
  # our slug (the matched API slug, or the wiki slug when WIP).
  #
  #   * "immunity" ("Immunity (quest)") — a stray inline
  #     `[[File:Intoxication.png|…]]` icon sits mid-sentence in its Guide.
  @guide_image_suppressed MapSet.new(["immunity"])

  # Inline `[[File:…]]` / `[[Image:…]]` ref (one nested `[[…]]` allowed in
  # the caption). Mirrors `Markup.strip_inline_file_refs/1`'s pattern but
  # is applied WITHOUT collapsing whitespace, so the section's newlines —
  # which the projection parses line-by-line — survive.
  @inline_file_ref ~r/\[\[(?:File|Image):[^\]\[]*(?:\[\[[^\]]+\]\][^\]\[]*)*\]\]/i

  defp suppress_guide_images(parsed_sections, %{normalized_name: slug}) do
    if MapSet.member?(@guide_image_suppressed, slug) do
      Enum.map(parsed_sections, &suppress_section_image/1)
    else
      parsed_sections
    end
  end

  # Drop the guide section's resolved files AND strip the inline file
  # ref(s) from its stored wikitext. Both are needed: the projection
  # re-parses the wikitext for images (so the ref must go), and an inline
  # ref would otherwise make the projection discard the whole prose line —
  # removing the ref leaves the surrounding description intact.
  defp suppress_section_image(%{section: %{slug: "guide"}} = parsed) do
    parsed
    |> Map.put(:files, [])
    |> Map.update!(:wikitext, &String.replace(&1, @inline_file_ref, ""))
  end

  defp suppress_section_image(parsed), do: parsed

  # ── Manifest ────────────────────────────────────────────────────────

  @doc """
  Assemble the `_quest.json` manifest from a quest, its wiki title, the
  parsed sections, and the resolved image-info map (keyed by
  `"File:"`-prefixed title).
  """
  def build_manifest(task, wiki_title, parsed_sections, info_map) do
    sections =
      Enum.map(parsed_sections, fn parsed ->
        s = parsed.section

        %{
          index: s.index,
          heading: s.heading,
          level: s.level,
          slug: s.slug,
          objectives:
            Enum.map(parsed.objectives, fn o ->
              %{index: o.index, text: o.text}
            end),
          files: Enum.map(parsed.files, &serialize_file(&1, info_map)),
          wikitext: parsed.wikitext
        }
      end)

    summary = %{
      total_files: parsed_sections |> Enum.flat_map(& &1.files) |> length(),
      total_objectives: parsed_sections |> Enum.flat_map(& &1.objectives) |> length()
    }

    %{
      task_id: task.id,
      task_name: task.name,
      normalized_name: task.normalized_name,
      wiki_title: wiki_title,
      wiki_link: task.wiki_link,
      # WIP: on the wiki but not (yet) in the DB synced from tarkov.dev.
      wip: task.wip,
      # The quest-giver (infobox `given by`), cleaned to a bare trader
      # name (e.g. "Ref", "Skier") for filtering. nil when absent.
      given_by: extract_given_by(parsed_sections),
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      sections: sections,
      summary: summary
    }
  end

  # Pull the infobox `|given by = [[Trader]]` value out of the lead
  # section's wikitext and clean it down to a bare trader name. nil when
  # the field is missing or empty.
  defp extract_given_by(parsed_sections) do
    case Enum.find(parsed_sections, fn p -> p.section.slug == "lead" end) do
      %{wikitext: wikitext} when is_binary(wikitext) -> parse_given_by(wikitext)
      _ -> nil
    end
  end

  defp parse_given_by(wikitext) do
    with [_, raw] <- Regex.run(~r/^[ \t]*\|[ \t]*given by[ \t]*=[ \t]*(.*)$/im, wikitext),
         value when value != "" <- String.trim(raw) do
      case caption_text(value) do
        "" -> nil
        cleaned -> cleaned
      end
    else
      _ -> nil
    end
  end

  defp serialize_file(f, info_map) do
    iinfo = Map.get(info_map, "File:" <> f.file) || %{}
    banner? = Map.get(f, :banner, false)

    %{
      banner: banner?,
      objective: f.objective,
      objective_text: f.objective_text,
      wiki_filename: f.file,
      wiki_title: "File:" <> f.file,
      caption: f.caption,
      url: iinfo["url"],
      mime: iinfo["mime"],
      width: iinfo["width"],
      height: iinfo["height"],
      # Credit data for the rare file that carries its own licence. The
      # File: page URL comes straight from the API rather than being built
      # from the filename, so title normalisation and redirects can't break
      # the link. `license` is nil for the vast majority of files.
      description_url: iinfo["descriptionurl"],
      uploader: iinfo["user"],
      license: iinfo["license"]
    }
  end

  # ── Banner (infobox image) extraction ──────────────────────────────

  defp add_banner_file(parse_result, wikitext) do
    case extract_banner_filename(wikitext) do
      nil ->
        parse_result

      banner ->
        banner_file = %{
          file: banner,
          caption: nil,
          preceding_text: nil,
          objective: nil,
          objective_text: nil,
          banner: true
        }

        %{parse_result | files: [banner_file | parse_result.files]}
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

  # ── Wikitext parser ─────────────────────────────────────────────────
  #
  # Walks a section's wikitext line-by-line, pulling out level-1 list
  # items (objectives) and `[[File:...]]` / `<gallery>` image refs, each
  # annotated with the text that precedes it. `skip_table_files?` drops
  # `[[File:…]]` refs inside a `{| … |}` wikitable (the "Related Quest
  # Items" icons), which DB-matched quests render from the API instead.

  @doc """
  Parse one section (`%{index, heading, level}`) and its wikitext into
  `%{section: %{index, heading, level, slug}, objectives: [...], files: [...]}`.
  """
  def parse_section(section, wikitext, skip_table_files?) do
    cleaned =
      wikitext
      |> strip_html_comments()
      |> strip_nowiki()

    initial_state = %{
      in_gallery: false,
      in_table: false,
      skip_table_files?: skip_table_files?,
      prev_paragraph: "",
      current_paragraph: "",
      last_was_break: false
    }

    {items, _state} =
      cleaned
      |> String.split("\n")
      |> Enum.reduce({[], initial_state}, &fold_line/2)

    items = Enum.reverse(items)

    {_file_refs_unused, objectives} = split_items(items)

    files = annotate_files_with_objectives(items)

    %{
      section: %{
        index: section.index,
        heading: section.heading,
        level: section.level,
        slug: slug_for_section(section)
      },
      objectives: objectives,
      files: files
    }
  end

  defp fold_line(line, {acc, state}) do
    cond do
      table_open?(line) ->
        {acc, %{state | in_table: true}}

      state.in_table and table_close?(line) ->
        {acc, %{state | in_table: false}}

      state.in_table and state.skip_table_files? ->
        {acc, state}

      gallery_open?(line) ->
        {acc, %{state | in_gallery: true}}

      state.in_gallery and gallery_close?(line) ->
        {acc, %{state | in_gallery: false}}

      state.in_gallery ->
        case parse_gallery_line(line) do
          nil ->
            {acc, state}

          ref ->
            ref = Map.put(ref, :preceding_text, ref.caption)
            {[ref | acc], state}
        end

      blank_line?(line) ->
        {acc, %{state | last_was_break: true}}

      true ->
        file_refs = extract_file_refs(line)

        case parse_list_marker(line) do
          {level, text} ->
            state1 = promote_current(state)
            state2 = %{state1 | current_paragraph: text, last_was_break: true}
            acc1 = [%{kind: :list_item, level: level, text: text} | acc]
            acc2 = attach_file_refs(file_refs, state2.current_paragraph, acc1)
            {acc2, state2}

          nil ->
            prose = extract_prose_text(line)

            cond do
              prose == "" and file_refs == [] ->
                {acc, state}

              prose == "" ->
                preceding = paragraph_for_image(state)
                acc1 = attach_file_refs(file_refs, preceding, acc)
                {acc1, %{state | last_was_break: true}}

              true ->
                state1 =
                  if state.last_was_break do
                    state
                    |> promote_current()
                    |> Map.put(:current_paragraph, prose)
                  else
                    appended =
                      case state.current_paragraph do
                        "" -> prose
                        existing -> existing <> " " <> prose
                      end

                    %{state | current_paragraph: appended}
                  end

                state2 = %{state1 | last_was_break: file_refs != []}
                acc1 = attach_file_refs(file_refs, state1.current_paragraph, acc)
                {acc1, state2}
            end
        end
    end
  end

  defp promote_current(%{current_paragraph: ""} = state), do: state

  defp promote_current(state) do
    %{state | prev_paragraph: state.current_paragraph, current_paragraph: ""}
  end

  defp paragraph_for_image(%{current_paragraph: cur}) when cur != "", do: cur
  defp paragraph_for_image(%{prev_paragraph: prev}), do: prev

  defp attach_file_refs(file_refs, preceding_text, acc) do
    Enum.reduce(file_refs, acc, fn ref, a ->
      [Map.put(ref, :preceding_text, preceding_text) | a]
    end)
  end

  defp blank_line?(line), do: String.trim(line) == ""

  defp extract_prose_text(line) do
    line
    |> strip_file_refs()
    |> strip_templates()
    |> caption_text()
  end

  defp strip_file_refs(line), do: do_strip_file_refs(line, 0, "")

  defp do_strip_file_refs(line, pos, out) when pos >= byte_size(line) do
    out <> :binary.part(line, pos, byte_size(line) - pos)
  end

  defp do_strip_file_refs(line, pos, out) do
    case :binary.match(line, "[[", scope: {pos, byte_size(line) - pos}) do
      :nomatch ->
        out <> :binary.part(line, pos, byte_size(line) - pos)

      {start, 2} ->
        prefix = :binary.part(line, pos, start - pos)

        case scan_wikilink(line, start + 2) do
          {:ok, inner, after_pos} ->
            if file_ref?(inner) do
              do_strip_file_refs(line, after_pos, out <> prefix <> " ")
            else
              full = :binary.part(line, start, after_pos - start)
              do_strip_file_refs(line, after_pos, out <> prefix <> full)
            end

          :error ->
            do_strip_file_refs(line, start + 2, out <> prefix <> "[[")
        end
    end
  end

  defp file_ref?(inner) do
    case String.split(inner, ":", parts: 2) do
      [prefix, _] -> String.downcase(String.trim(prefix)) in ["file", "image"]
      _ -> false
    end
  end

  defp strip_templates(s), do: strip_templates(s, nil)
  defp strip_templates(s, s), do: s

  defp strip_templates(s, _prev) do
    case Regex.replace(~r/\{\{[^{}]*\}\}/, s, " ") do
      ^s -> s
      replaced -> strip_templates(replaced, s)
    end
  end

  defp parse_list_marker(line) do
    trimmed = String.trim_trailing(line)

    case Regex.run(~r/^([*#]+)\s*(.*)$/, trimmed) do
      [_, markers, text] ->
        text =
          text
          |> strip_inline_file_refs()
          |> caption_text()

        if text == "", do: nil, else: {String.length(markers), text}

      _ ->
        nil
    end
  end

  defp extract_file_refs(line), do: do_extract_file_refs(line, 0, [])

  defp do_extract_file_refs(line, pos, acc) when pos >= byte_size(line),
    do: Enum.reverse(acc)

  defp do_extract_file_refs(line, pos, acc) do
    case :binary.match(line, "[[", scope: {pos, byte_size(line) - pos}) do
      :nomatch ->
        Enum.reverse(acc)

      {start, 2} ->
        case scan_wikilink(line, start + 2) do
          {:ok, inner, after_pos} ->
            case parse_file_ref(inner) do
              nil -> do_extract_file_refs(line, after_pos, acc)
              ref -> do_extract_file_refs(line, after_pos, [ref | acc])
            end

          :error ->
            do_extract_file_refs(line, start + 2, acc)
        end
    end
  end

  defp parse_file_ref(inner) do
    case split_pipes_depth_aware(inner) do
      [head | rest] ->
        case extract_file_name(head) do
          nil -> nil
          name -> %{kind: :file, file: name, caption: pick_caption(rest)}
        end

      [] ->
        nil
    end
  end

  defp extract_file_name(head) do
    case Regex.run(~r/^\s*(?:file|image)\s*:\s*(.+)$/is, head) do
      [_, rest] -> normalize_filename(rest)
      _ -> nil
    end
  end

  defp pick_caption(segments) do
    segments
    |> Enum.reverse()
    |> Enum.find(&caption_segment?/1)
    |> case do
      nil -> nil
      seg -> seg |> String.trim() |> caption_text()
    end
  end

  defp caption_segment?(seg) do
    s = String.trim(seg)

    cond do
      s == "" -> false
      s in @image_modifiers -> false
      Regex.match?(~r/^\d+px$/, s) -> false
      Regex.match?(~r/^x\d+px$/, s) -> false
      Regex.match?(~r/^\d+x\d+px$/, s) -> false
      kv_modifier?(s) -> false
      true -> true
    end
  end

  defp kv_modifier?(s) do
    case String.split(s, "=", parts: 2) do
      [k, _v] -> String.trim(k) in @image_modifier_kv_keys
      _ -> false
    end
  end

  defp caption_text(nil), do: ""

  defp caption_text(s) do
    s
    |> String.replace(~r/\[\[([^\|\]]+)\|([^\]]+)\]\]/, "\\2")
    |> String.replace(~r/\[\[([^\]]+)\]\]/, "\\1")
    # Strip bold/italic as raw runs (not `'''(...)'''`) so emphasised
    # text containing an apostrophe (e.g. "didn't") is still cleaned.
    |> String.replace("'''''", "")
    |> String.replace("'''", "")
    |> String.replace("''", "")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp gallery_open?(line),
    do: Regex.match?(~r/<gallery\b[^>]*>/i, line)

  # Wikitable delimiters. MediaWiki tables open with `{|` and close with
  # `|}` (each on its own line, optionally indented). We don't handle
  # nesting — quest "Related Quest Items" tables are always flat.
  defp table_open?(line),
    do: line |> String.trim_leading() |> String.starts_with?("{|")

  defp table_close?(line),
    do: line |> String.trim_leading() |> String.starts_with?("|}")

  defp gallery_close?(line),
    do: Regex.match?(~r/<\/gallery>/i, line)

  defp parse_gallery_line(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        nil

      String.starts_with?(line, "<") ->
        nil

      true ->
        case String.split(line, "|", parts: 2) do
          [file] ->
            %{kind: :file, file: normalize_filename(file), caption: nil}

          [file, cap] ->
            %{kind: :file, file: normalize_filename(file), caption: caption_text(cap)}
        end
    end
  end

  # Strip any (possibly repeated/typo'd) File:/Image: prefix and
  # canonicalize the way MediaWiki does — underscores become spaces and
  # the first letter is upper-cased — so the manifest key matches the
  # filename we resolve and the storyline pipeline's
  # `EftBuddy.Chapters.Dump.normalize_filename/1` byte-for-byte. The
  # read-time loaders re-normalize both sides anyway (lowercase +
  # `_`→space), so this is a belt-and-braces consistency guarantee
  # rather than the sole correctness mechanism.
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

  # Walk the parsed item stream and pull out the level-1 list items
  # (objectives), in document order.
  defp split_items(items) do
    {files, objs, _} =
      Enum.reduce(items, {[], [], 0}, fn item, {fs, os, obj_idx} ->
        case item do
          %{kind: :list_item, level: 1, text: t} ->
            new_idx = obj_idx + 1
            {fs, [%{index: new_idx, text: t} | os], new_idx}

          %{kind: :list_item} ->
            {fs, os, obj_idx}

          %{kind: :file} = f ->
            {[f | fs], os, obj_idx}
        end
      end)

    {Enum.reverse(files), Enum.reverse(objs)}
  end

  # For each file ref, attach the index and text of the most recent
  # level-1 list item above it (or nil if the section has no list).
  defp annotate_files_with_objectives(items) do
    {annotated, _, _} =
      Enum.reduce(items, {[], 0, nil}, fn item, {acc, obj_idx, last_text} ->
        case item do
          %{kind: :list_item, level: 1, text: t} ->
            {acc, obj_idx + 1, t}

          %{kind: :list_item} ->
            {acc, obj_idx, last_text}

          %{kind: :file} = f ->
            entry = %{
              file: f.file,
              caption: f.caption,
              preceding_text: Map.get(f, :preceding_text),
              objective: if(obj_idx > 0, do: obj_idx, else: nil),
              objective_text: if(obj_idx > 0, do: last_text, else: nil)
            }

            {[entry | acc], obj_idx, last_text}
        end
      end)

    Enum.reverse(annotated)
  end

  defp slug_for_section(%{heading: "(lead / infobox)"}), do: "lead"

  defp slug_for_section(%{heading: line}) do
    line
    |> caption_text()
    |> Slug.slugify()
    |> case do
      "" -> "section"
      s -> s
    end
  end

  @doc """
  Sanitise a quest name into a filesystem-safe directory name
  (filesystem-illegal characters become dashes, whitespace collapsed).
  """
  def sanitize_dirname(name) do
    name
    |> String.replace(~r/[\/\\:*?"<>|]/, "-")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
