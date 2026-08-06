defmodule EftBuddy.Events.Sync do
  @moduledoc """
  Scrapes the EFT Fandom "Events" page (and each event quest's own wiki
  page) into the `events` + `event_quests` tables.

  Third wiki scraper alongside `EftBuddy.Wiki.Sync` (quests) and
  `EftBuddy.Chapters.Sync` (storyline), and scheduled the same way: a
  background run a short while after boot, then daily. Can also be
  triggered synchronously from IEx:

      EftBuddy.Events.Sync.run()

  Pipeline (the pure parsing lives in `EftBuddy.Events.Dump`; the quest-
  page scraping reuses `EftBuddy.Wiki.Dump`, so this module is only the
  impure glue):

    1. Fetch the "Events" page wikitext and parse it into per-event
       records (`EftBuddy.Events.Dump.parse_events_page/1`).
    2. Resolve every event banner image to its Fandom CDN url.
    3. Scrape each distinct event quest's own page through the exact
       `EftBuddy.Wiki.Dump` pipeline the quest sync uses, so an event
       quest's stored manifest is identical to a `wiki_quests` row and
       `EftBuddy.Wiki.Projection` renders it the same way.
    4. Upsert one `events` row per event and one `event_quests` row per
       (event, quest); prune events and per-event quests that have
       vanished from the page.

  ## Why this scrapes the quest pages itself

  Event quests are deliberately blacklisted from `EftBuddy.Wiki.Sync`
  (so they stop showing as WIP on the Tasks tab — see
  `EftBuddy.Events.blacklisted_quest_slugs/0`). To avoid losing their
  walkthroughs, this sync owns scraping them. The net wiki load is
  roughly unchanged: the same quest pages are simply scraped here
  instead of by the quest sync. It is scheduled BEFORE `Wiki.Sync` so
  the blacklist the quest sync reads is already fresh.

  ## Defensiveness

  A scrape that can't see its data never wipes good rows:

    * Events page fetch fails / parses to zero events → skip, keep
      existing rows, retry on the normal cadence.
    * A single quest page that fails to fetch is isolated by
      `EftBuddy.Wiki.Dump.run/2`; its `event_quests` row is still written
      (without a manifest) so the quest still lists on the tab.
  """

  # Second of the three Fandom scrapes. Bootstrap RELEASES this one — it has not
  # run at that point — a minute after the chapter scrape, so the two never hit
  # the Fandom API at once and the tasks table the best-effort event-quest
  # matcher reads is already populated.
  #
  # `after_run/1` below chains the quest scrape off this one's completion.
  use EftBuddy.Sync.Scheduler,
    label: "EventsSync",
    interval: 24 * 60 * 60 * 1_000,
    stagger: 1 * 60 * 1_000,
    bootstrap: :released,
    config_key: :events

  require Logger
  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Tasks.Task
  alias EftBuddy.Events.{Event, EventQuest}
  alias EftBuddy.Events.Dump, as: EventsDump
  alias EftBuddy.Wiki.Dump, as: WikiDump
  alias EftBuddy.Wiki.{Contributors, DumpScript, FileLicense}
  alias EftBuddy.Sync.Reporter

  @api_url "https://escapefromtarkov.fandom.com/api.php"
  @events_page "Events"
  @imageinfo_batch 50

  @event_replace_on_conflict [
    :name,
    :event_date,
    :started_on,
    :status,
    :position,
    :banner_url,
    :description,
    :content,
    :updated_at
  ]

  @event_quest_replace_on_conflict [:name, :task_id, :position, :content, :updated_at]

  @impl EftBuddy.Sync.Scheduler
  # Hand off to the quest scrape now that this run has refreshed the
  # `event_quests` table its blacklist reads. Chaining on COMPLETION rather than
  # using a fixed offset guarantees the blacklist is fully written before the
  # quest scrape starts — it fixed a cold-start race where event quests still
  # showed as WIP — and it keeps the two heaviest Fandom scrapes apart.
  def after_run(_result) do
    GenServer.cast({:global, EftBuddy.Wiki.Sync}, :events_complete)
    :ok
  end

  # ── Pipeline ───────────────────────────────────────────

  @impl EftBuddy.Sync.Scheduler
  def do_run do
    Reporter.with_run("EventsSync", &run_pipeline/0)
  end

  defp run_pipeline do
    case fetch_events_wikitext() do
      {:error, reason} ->
        Logger.error(
          "[#{prefix()}] couldn't fetch the Events page (#{inspect(reason)}); keeping existing rows."
        )

        {:error, reason}

      {:ok, wikitext} ->
        case EventsDump.parse_events_page(wikitext) do
          [] ->
            Logger.error(
              "[#{prefix()}] parsed 0 events from the Events page; keeping existing rows."
            )

            {:error, :empty_page}

          events ->
            scrape_and_upsert(events)
        end
    end
  end

  defp scrape_and_upsert(events) do
    fetched_at = DateTime.utc_now() |> DateTime.to_iso8601()

    banner_map = resolve_banner_urls(events)
    manifests = scrape_quest_manifests(events)

    {processed_slugs, quest_count} =
      Enum.reduce(events, {[], 0}, fn event, {slugs, qcount} ->
        {:ok, row} = upsert_event(event, banner_map, fetched_at)
        upsert_event_quests(row, event, manifests)
        {[event.normalized_name | slugs], qcount + length(event.quests)}
      end)

    pruned = prune_events(processed_slugs)

    {:ok,
     %{
       events: length(events),
       quests: quest_count,
       scraped: map_size(manifests),
       pruned: pruned
     }}
  end

  # ── Event upsert ───────────────────────────────────────

  defp upsert_event(event, banner_map, fetched_at) do
    banner_url = Map.get(banner_map, event.banner_filename)
    content = EventsDump.build_event_content(event, banner_url, fetched_at) |> json_round_trip()

    attrs = %{
      normalized_name: event.normalized_name,
      name: event.name,
      event_date: event.event_date,
      started_on: event.started_on,
      status: event.status,
      position: event.position,
      banner_url: banner_url,
      description: event.description,
      content: content
    }

    with {:ok, _} <-
           %Event{}
           |> Event.changeset(attrs)
           |> Repo.insert(
             on_conflict: {:replace, @event_replace_on_conflict},
             conflict_target: :normalized_name
           ) do
      # binary_id PKs are client-generated, so on a conflict the struct
      # returned by `insert` carries the throwaway id, not the existing
      # row's. Re-read by the stable slug to get the real id the quests
      # must FK against.
      {:ok, Repo.get_by!(Event, normalized_name: event.normalized_name)}
    end
  end

  # ── Event-quest upsert + per-event prune ───────────────

  defp upsert_event_quests(%Event{id: event_id}, event, manifests) do
    slugs = Enum.map(event.quests, & &1.slug)

    # Drop quests this event no longer lists (the cross-event prune in
    # `prune_events/1` only deletes rows for whole vanished events).
    Repo.delete_all(
      from(eq in EventQuest,
        where: eq.event_id == ^event_id and eq.normalized_name not in ^slugs
      )
    )

    event.quests
    |> Enum.with_index()
    |> Enum.each(fn {quest, idx} -> upsert_event_quest(event_id, quest, idx, manifests) end)
  end

  defp upsert_event_quest(event_id, quest, position, manifests) do
    manifest = Map.get(manifests, quest.slug)
    content = if manifest, do: json_round_trip(manifest), else: %{}
    task_id = manifest && Map.get(manifest, :task_id)

    attrs = %{
      event_id: event_id,
      normalized_name: quest.slug,
      name: quest.name,
      task_id: task_id,
      position: position,
      content: content
    }

    %EventQuest{}
    |> EventQuest.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @event_quest_replace_on_conflict},
      conflict_target: [:event_id, :normalized_name]
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  # Delete rows for events no longer on the page (their `event_quests`
  # cascade away via the FK's `on_delete: :delete_all`). Safe because we
  # only reach here after a non-empty parse.
  defp prune_events(processed_slugs) do
    {deleted, _} =
      Repo.delete_all(from(e in Event, where: e.normalized_name not in ^processed_slugs))

    deleted
  end

  # ── Quest-page scraping (reuses the quest dump pipeline) ───────────

  # Scrape every distinct event quest's wiki page through the SAME
  # `EftBuddy.Wiki.Dump` pipeline the quest sync uses, collecting each
  # quest's manifest by slug. The injected `write` accumulates into an
  # Agent rather than persisting, so we can fan the one manifest out to
  # every (event, quest) row afterwards.
  defp scrape_quest_manifests(events) do
    quest_titles = EventsDump.unique_quest_titles(events)

    if quest_titles == [] do
      %{}
    else
      db_index = WikiDump.build_db_index(load_db_rows())
      quests = Enum.map(quest_titles, fn q -> WikiDump.build_quest(q.wiki_title, db_index) end)

      # Each event quest has its own wiki page, so each carries its own
      # authors. The event rows themselves are all scraped from the single
      # shared "Events" page, so there is no per-event roster to fetch.
      rosters = Contributors.fetch(Enum.map(quests, & &1.wiki_title), http_opts())

      {:ok, agent} = Agent.start_link(fn -> %{} end)

      try do
        WikiDump.run(quests,
          fetch: &fetch_quest_sections/1,
          resolve: &resolve_image_urls/1,
          write: fn quest, manifest ->
            manifest = Contributors.merge(manifest, Map.get(rosters, quest.wiki_title))
            Agent.update(agent, &Map.put(&1, quest.normalized_name, manifest))
            :ok
          end
        )

        Agent.get(agent, & &1)
      after
        Agent.stop(agent)
      end
    end
  end

  defp load_db_rows do
    Repo.all(
      from(t in Task,
        select: %{id: t.id, name: t.name, normalized_name: t.normalized_name},
        order_by: t.normalized_name
      )
    )
  end

  # ── Wiki HTTP (impure glue, mirrors Wiki.Sync) ─────────

  defp http_opts, do: [url: @api_url, user_agent: DumpScript.user_agent()]

  defp fetch_events_wikitext do
    case DumpScript.api_get(
           %{
             "action" => "parse",
             "page" => @events_page,
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

  # Build the section list (incl. the synthesized lead) and fetch each
  # section's wikitext for one quest — identical to the quest sync, so
  # the manifest shape matches `wiki_quests.content` exactly.
  defp fetch_quest_sections(quest) do
    case fetch_sections(quest.wiki_title) do
      {:error, reason} ->
        {:error, reason}

      {:ok, sections_list} ->
        sections_list = [%{index: "0", heading: "(lead / infobox)", level: "0"} | sections_list]

        raw =
          Enum.map(sections_list, fn s ->
            %{
              index: s.index,
              heading: s.heading,
              level: s.level,
              wikitext: fetch_wikitext_section(quest.wiki_title, s.index)
            }
          end)

        {:ok, raw}
    end
  end

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
          |> Enum.map(fn s -> %{index: s["index"], heading: s["line"], level: s["level"]} end)

        {:ok, list}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
      {:ok, body} ->
        get_in(body, ["parse", "wikitext"]) || ""

      {:error, reason} ->
        Reporter.silent_warn(
          "[#{prefix()}] wikitext section #{section_index} of #{title} failed: #{inspect(reason)}"
        )

        ""
    end
  end

  # File-title-keyed image resolution for the quest dump (keys are
  # `"File:"`-prefixed, matching `EftBuddy.Wiki.Dump.serialize_file/2`).
  defp resolve_image_urls(file_titles) do
    info =
      file_titles
      |> Enum.uniq()
      |> Enum.chunk_every(@imageinfo_batch)
      |> Enum.flat_map(fn batch -> resolve_image_batch(batch, & &1) end)
      |> Map.new()

    licenses = FileLicense.fetch(Map.keys(info), http_opts())

    Map.new(info, fn {title, iinfo} ->
      {title, Map.put(iinfo, "license", Map.get(licenses, title))}
    end)
  end

  # Bare-filename-keyed resolution for event banners. The parsed records
  # carry bare filenames; we prefix `File:` for the query and map the
  # resolved url back to the bare key the records use.
  defp resolve_banner_urls(events) do
    events
    |> Enum.map(& &1.banner_filename)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.chunk_every(@imageinfo_batch)
    |> Enum.flat_map(fn batch ->
      batch
      |> Enum.map(&("File:" <> &1))
      |> resolve_image_batch(&strip_file_prefix/1)
    end)
    |> Map.new(fn {key, iinfo} -> {key, iinfo["url"]} end)
  end

  # Resolve a batch of `"File:"`-prefixed titles to imageinfo, keying the
  # result by `key_fun.(original_title)` so callers choose prefixed
  # (quest dump) or bare (banners) keys. MediaWiki normalizes/redirects
  # titles, so we invert those rewrites to recover the title we sent.
  defp resolve_image_batch(titles, key_fun) do
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
          %{"missing" => true} -> []
          %{"title" => t, "imageinfo" => [iinfo | _]} -> [{key_fun.(original_for.(t)), iinfo}]
          _ -> []
        end)

      {:error, reason} ->
        Reporter.silent_warn("[#{prefix()}] imageinfo batch failed: #{inspect(reason)}")
        []
    end
  end

  defp strip_file_prefix("File:" <> rest), do: rest
  defp strip_file_prefix(other), do: other

  # Round-trip an atom-keyed manifest/content map through JSON so it's
  # stored string-keyed (exactly what a JSONB read returns), matching
  # `wiki_quests` / `wiki_chapters` and what `EftBuddy.Wiki.Projection`
  # expects at read time.
  defp json_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
end
