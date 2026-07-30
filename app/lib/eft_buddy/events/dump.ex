defmodule EftBuddy.Events.Dump do
  @moduledoc """
  Pure, side-effect-free parser for the EFT Fandom "Events" page.

  The impure runner — `EftBuddy.Events.Sync` — injects the MediaWiki API
  calls (fetch the Events page wikitext, scrape each event quest's own
  page, resolve banner image urls) and the DB upserts, so everything
  here is deterministic and unit-testable. Companion to
  `EftBuddy.Wiki.Dump` / `EftBuddy.Chapters.Dump`.

  ## What it parses

  The Events page is a flat list of level-2 sections, one per event:

      ==Wild Wild Woods (25 June 2026)==
      <li ...><gallery ...>File:Wild Wild Woods Banner.png</gallery></li>
      {{quote|A Scav mutiny has occurred: ...}}
      '''Gameplay Changes'''
      * Quest [[Wild Wild Woods]] has been added.
      * New Barters for [[Silver Badge]]s.
      ...

  `parse_events_page/1` turns that into one record per event:

    * `name` / `event_date` — from the `Name (date)` heading.
    * `started_on` — the parsed start date, for newest-first sorting
      (nil when unparseable; ranges like `20-27 June 2022` use the first
      day).
    * `status` — `"active"` for events above the wiki's "past events"
      divider table, `"past"` below it.
    * `position` — 0-based order on the page (already newest-first).
    * `banner_filename` — the first `<gallery>` image before the first
      bullet (resolved to a CDN url later by the sync).
    * `description` — the `{{quote}}` blurb (nil when absent).
    * `availability_note` — e.g. "Not available in the PvE game mode."
    * `quests` — the `Quest [[Name]] has been added.` references.
    * `gameplay_changes` — every other list bullet (`%{level, text}`).

  ## Robustness notes (driven by the real page)

    * Many events have NO `'''Gameplay Changes'''` header — bullets
      follow the banner directly — so the header is never required.
    * Banner gallery files appear with or without a `File:` prefix.
    * A quest bullet is `[Temporary|New] Quest [[Target|Display]]` whose
      text mentions added/available/started; the slug comes from the
      link TARGET (so it matches the wiki page title), the display name
      from the label. Lines like `Story chapter [[Boreas]] has been
      added.` or `[[Icebreaker]] location has been added.` are NOT
      quests (no `Quest` keyword) and stay in gameplay changes.
    * Wikitables (`{| … |}`: boss timetables, ammo tables, tabbers) are
      stripped before bullets are collected so their cells don't leak in.
  """

  alias EftBuddy.Wiki.Slug
  import EftBuddy.Wiki.Markup, only: [clean_text: 1, strip_inline_file_refs: 1]

  @wiki_base "https://escapefromtarkov.fandom.com/wiki/"
  @past_divider "This section describes past events"

  @months %{
    "january" => 1,
    "february" => 2,
    "march" => 3,
    "april" => 4,
    "may" => 5,
    "june" => 6,
    "july" => 7,
    "august" => 8,
    "september" => 9,
    "october" => 10,
    "november" => 11,
    "december" => 12
  }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Parse the raw Events-page wikitext into an ordered list of event
  records (page order, newest first). See the moduledoc for the shape.
  """
  def parse_events_page(wikitext) when is_binary(wikitext) do
    wikitext
    |> String.split(~r/\r?\n/)
    |> chunk_events()
    |> Enum.with_index()
    |> Enum.map(fn {{title, status, body_lines}, idx} ->
      build_event(title, status, body_lines, idx)
    end)
  end

  @doc """
  The de-duplicated set of event quests across all events, as the quest
  structs `EftBuddy.Wiki.Dump.build_quest/2`-style scraping operates on
  (`%{wiki_title, slug, name}`). Deduped by slug — a quest added by two
  events is scraped once.
  """
  def unique_quest_titles(events) when is_list(events) do
    events
    |> Enum.flat_map(& &1.quests)
    |> Enum.uniq_by(& &1.slug)
  end

  @doc """
  Build the `content` JSONB payload for an event row from its parsed
  record and the resolved banner url. Atom-keyed; the sync JSON-round-
  trips it (like the other wiki syncs) so it is stored string-keyed.
  """
  def build_event_content(event, banner_url, fetched_at) do
    %{
      availability_note: event.availability_note,
      gameplay_changes: event.gameplay_changes,
      quests:
        Enum.map(event.quests, fn q ->
          %{name: q.name, slug: q.slug, wiki_title: q.wiki_title, wiki_link: q.wiki_link}
        end),
      banner: %{filename: event.banner_filename, url: banner_url},
      wiki_link: event.wiki_link,
      fetched_at: fetched_at
    }
  end

  @doc "Lowercase, dash-joined slug derived from a name."
  defdelegate normalize_name(name), to: Slug

  # ── Sectioning ──────────────────────────────────────────────────────

  # Walk the page line-by-line, splitting on level-2 headings. The
  # "past events" divider flips a flag so every event started after it is
  # tagged "past"; events before it (and the one whose body contains the
  # divider) are "active".
  defp chunk_events(lines) do
    {events, current, _past?} =
      Enum.reduce(lines, {[], nil, false}, fn line, {events, current, past?} ->
        past? = past? or String.contains?(line, @past_divider)

        case level2_heading(line) do
          nil ->
            case current do
              nil -> {events, nil, past?}
              {title, status, body} -> {events, {title, status, [line | body]}, past?}
            end

          title ->
            status = if past?, do: "past", else: "active"
            {flush(current, events), {title, status, []}, past?}
        end
      end)

    flush(current, events) |> Enum.reverse()
  end

  defp flush(nil, events), do: events
  defp flush({title, status, body}, events), do: [{title, status, Enum.reverse(body)} | events]

  # A level-2 heading is exactly `== Title ==` — the `[^=]` guard after
  # the opening `==` rejects level-3+ (`===Frostbite===`) so sub-sections
  # stay part of their event's body.
  defp level2_heading(line) do
    case Regex.run(~r/^\s*==\s*([^=].*?)\s*==\s*$/, line) do
      [_, title] -> String.trim(title)
      _ -> nil
    end
  end

  # ── Per-event assembly ──────────────────────────────────────────────

  defp build_event(title, status, body_lines, position) do
    {name, date_str} = parse_heading(title)
    body = Enum.join(body_lines, "\n")
    {quests, gameplay_changes} = extract_bullets(body)

    %{
      normalized_name: Slug.normalize_name(title),
      name: name,
      event_date: date_str,
      started_on: parse_date(date_str),
      status: status,
      position: position,
      banner_filename: extract_banner(body_lines),
      description: extract_quote(body),
      availability_note: extract_availability_note(body_lines),
      quests: quests,
      gameplay_changes: gameplay_changes,
      wiki_link: @wiki_base <> String.replace(title, " ", "_")
    }
  end

  # Split `Name (date)` — the trailing parenthesised group is the date.
  defp parse_heading(title) do
    case Regex.run(~r/^(.*?)\s*\(([^()]*)\)\s*$/, title) do
      [_, name, date] -> {String.trim(name), String.trim(date)}
      _ -> {String.trim(title), nil}
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Regex.run(~r/(\d{1,2})(?:\s*[-–—]\s*\d{1,2})?\s+([A-Za-z]+)\s+(\d{4})/, str) do
      [_, day, month, year] ->
        with {d, _} <- Integer.parse(day),
             {y, _} <- Integer.parse(year),
             m when is_integer(m) <- Map.get(@months, String.downcase(month)),
             {:ok, date} <- Date.new(y, m, d) do
          date
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ── Banner ──────────────────────────────────────────────────────────

  # The banner is the first gallery image that appears before the first
  # list bullet. The wiki writes it as a `<li><gallery>` block with the
  # filename on its own line, so scan to the first `<gallery`, then take
  # the first non-tag content line as the filename.
  defp extract_banner(lines), do: scan_banner(lines, :before)

  defp scan_banner([], _state), do: nil

  defp scan_banner([line | rest], :before) do
    t = String.trim(line)

    cond do
      bullet_line?(t) -> nil
      String.contains?(t, "<gallery") -> scan_banner(rest, :in)
      true -> scan_banner(rest, :before)
    end
  end

  defp scan_banner([line | rest], :in) do
    t = String.trim(line)

    cond do
      t == "" -> scan_banner(rest, :in)
      String.starts_with?(t, "</gallery") -> nil
      String.starts_with?(t, "<") -> scan_banner(rest, :in)
      true -> gallery_filename(t)
    end
  end

  defp gallery_filename(line) do
    line
    |> String.split("|")
    |> List.first()
    |> normalize_filename()
    |> case do
      "" -> nil
      name -> name
    end
  end

  # ── Description ({{quote}}) ──────────────────────────────────────────

  defp extract_quote(body) do
    case Regex.run(~r/\{\{\s*quote\s*\|(.+?)\}\}/is, body) do
      [_, inner] ->
        case clean_text(inner) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  # ── Availability note ───────────────────────────────────────────────

  defp extract_availability_note(lines) do
    Enum.find_value(lines, fn line ->
      t = String.trim(line)

      if Regex.match?(~r/^'''\s*Not available.*'''/i, t) do
        case clean_text(t) do
          "" -> nil
          text -> text
        end
      end
    end)
  end

  # ── Bullets → {quests, gameplay_changes} ────────────────────────────

  defp extract_bullets(body) do
    {quests, changes} =
      body
      |> strip_wikitables()
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({[], []}, fn line, {quests, changes} ->
        case Regex.run(~r/^\s*([*#]+)\s*(.+?)\s*$/, line) do
          [_, markers, raw] ->
            case parse_quest_bullet(raw) do
              nil ->
                case clean_text(strip_inline_file_refs(raw)) do
                  "" -> {quests, changes}
                  text -> {quests, [%{level: String.length(markers), text: text} | changes]}
                end

              quest ->
                {[quest | quests], changes}
            end

          _ ->
            {quests, changes}
        end
      end)

    {quests |> Enum.reverse() |> Enum.uniq_by(& &1.slug), Enum.reverse(changes)}
  end

  # Blank out `{| … |}` wikitables (non-nesting) so the cells of boss
  # timetables / ammo tables / tabbers don't get collected as changes.
  defp strip_wikitables(body), do: Regex.replace(~r/\{\|.*?\|\}/s, body, " ")

  # A quest bullet: optional "Temporary "/"New " then "Quest" then a
  # wikilink, with the text mentioning added/available/started. The slug
  # comes from the link target (matches the wiki page title); the name
  # from the display label.
  defp parse_quest_bullet(raw) do
    with true <- Regex.match?(~r/\b(added|available|started)\b/i, raw),
         [_, link] <- Regex.run(~r/^\s*(?:Temporary\s+|New\s+)?Quest\s+\[\[([^\]]+)\]\]/i, raw) do
      {target, display} = split_link(link)
      slug = Slug.normalize_name(target)

      if slug == "" do
        nil
      else
        %{
          name: display_name(display),
          slug: slug,
          wiki_title: target,
          wiki_link: @wiki_base <> String.replace(target, " ", "_")
        }
      end
    else
      _ -> nil
    end
  end

  # Split a `[[Target|Display]]` body into its target page title and
  # display label, dropping any `#anchor` from the target.
  defp split_link(link) do
    {target, display} =
      case String.split(link, "|", parts: 2) do
        [t, d] -> {t, d}
        [t] -> {t, t}
      end

    target = target |> String.split("#") |> List.first() |> String.trim()
    {target, String.trim(display)}
  end

  defp display_name(display) do
    case clean_text(display) do
      "" -> display
      cleaned -> cleaned
    end
  end

  # ── Small helpers ───────────────────────────────────────────────────

  defp bullet_line?(t), do: Regex.match?(~r/^[*#]/, t)

  # Strip any File:/Image: prefix and canonicalize like MediaWiki
  # (underscores → spaces, first letter upper-cased), mirroring the
  # quest/chapter dumps so the key matches the resolved-url map.
  defp normalize_filename(name) do
    name
    |> to_string()
    |> String.trim()
    |> strip_file_prefix()
    |> String.replace("_", " ")
    |> String.trim()
    |> upcase_first()
  end

  defp strip_file_prefix(name) do
    case Regex.run(~r/^\s*(?:file|image)\s*:\s*(.*)$/is, name) do
      [_, rest] -> strip_file_prefix(rest)
      _ -> name
    end
  end

  defp upcase_first(""), do: ""
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
