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

  # Second of the three Fandom scrapes, run by Bootstrap inside the cold start
  # after Tasks, so the tasks table the best-effort event-quest matcher reads is
  # already populated on a fresh database. The stagger below is only this feed's
  # slot in the recurring cycle — it is NOT a delay to the first run, which is
  # what it silently became while this feed was `:released`.
  #
  # `after_run/1` below chains the quest scrape off this one's completion, which
  # is how the two stay ordered on the recurring cycle. The cold start orders
  # them directly instead: it calls `run/0`, which does not go through
  # `after_run/1`.
  use EftBuddy.Sync.Scheduler,
    label: "EventsSync",
    interval: 12 * 60 * 60 * 1_000,
    stagger: 180 * 60 * 1_000,
    bootstrap: :ran,
    config_key: :events

  require Logger
  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Tasks.Task
  alias EftBuddy.Events.{Event, EventQuest}
  alias EftBuddy.Events.Dump, as: EventsDump
  alias EftBuddy.Wiki.Dump, as: WikiDump
  alias EftBuddy.Wiki.{Api, Contributors}
  alias EftBuddy.Sync.Reporter

  @events_page "Events"

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

  # When a quest page failed to scrape this run there is no manifest, and the
  # stored walkthrough is the best copy there is: only the fields the Events page
  # itself gives are refreshed (audit M21). It used to be overwritten with `%{}`,
  # so one transient failure blanked the walkthrough for twelve hours.
  @event_quest_listing_only [:name, :position, :updated_at]

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
    case Api.page_wikitext(@events_page) do
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
    {manifests, scrape} = scrape_quest_manifests(events)

    # Every parsed event stays in the keep-set even when its row could not be
    # written, so a bad row keeps its previous version rather than being pruned.
    processed_slugs = Enum.map(events, & &1.normalized_name)

    quest_count =
      Enum.reduce(events, 0, fn event, qcount ->
        case upsert_event(event, banner_map, fetched_at) do
          {:ok, row} ->
            upsert_event_quests(row, event, manifests)

          # One event the parser got wrong (a heading like `==(25 June 2026)==`
          # yields an empty name) used to raise a MatchError here and abort the
          # whole sync on every run (audit M25). It is counted and skipped.
          {:error, changeset} ->
            Reporter.silent_warn(
              "[#{prefix()}] event #{inspect(event.name)} not written: #{inspect(changeset.errors)}"
            )
        end

        qcount + length(event.quests)
      end)

    # Events no longer on the page; their `event_quests` cascade away via the
    # FK's `on_delete: :delete_all`. We only reach here after a non-empty parse,
    # and `Api.prune/2` refuses one that would drop most of the table.
    pruned = Api.prune(Event, processed_slugs)

    Api.scrape_result(
      %{
        events: length(events),
        quests: quest_count,
        scraped: map_size(manifests),
        failed: scrape.failed,
        pruned: pruned
      },
      scrape.processed + scrape.failed,
      scrape.failed
    )
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
    |> Enum.each(fn {quest, idx} ->
      case upsert_event_quest(event_id, quest, idx, manifests) do
        :ok ->
          :ok

        {:error, errors} ->
          Reporter.silent_warn(
            "[#{prefix()}] event quest #{inspect(quest.name)} not written: #{inspect(errors)}"
          )
      end
    end)
  end

  defp upsert_event_quest(event_id, quest, position, manifests) do
    manifest = Map.get(manifests, quest.slug)
    content = if manifest, do: json_round_trip(manifest), else: %{}
    task_id = manifest && Map.get(manifest, :task_id)

    replace =
      if manifest, do: @event_quest_replace_on_conflict, else: @event_quest_listing_only

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
      on_conflict: {:replace, replace},
      conflict_target: [:event_id, :normalized_name]
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  # ── Quest-page scraping (reuses the quest dump pipeline) ───────────

  # Scrape every distinct event quest's wiki page through the SAME
  # `EftBuddy.Wiki.Dump` pipeline the quest sync uses, collecting each
  # quest's manifest by slug. The injected `write` accumulates into an
  # Agent rather than persisting, so we can fan the one manifest out to
  # every (event, quest) row afterwards.
  #
  # Returns `{manifests, %{processed: n, failed: n}}`. The counts used to be
  # dropped, which is how a run where every quest page failed still reported ok.
  defp scrape_quest_manifests(events) do
    quest_titles = EventsDump.unique_quest_titles(events)

    if quest_titles == [] do
      {%{}, %{processed: 0, failed: 0}}
    else
      db_index = WikiDump.build_db_index(load_db_rows())
      quests = Enum.map(quest_titles, fn q -> WikiDump.build_quest(q.wiki_title, db_index) end)

      # Each event quest has its own wiki page, so each carries its own
      # authors. The event rows themselves are all scraped from the single
      # shared "Events" page, so there is no per-event roster to fetch.
      rosters = Contributors.fetch(Enum.map(quests, & &1.wiki_title), Api.http_opts())

      {:ok, agent} = Agent.start_link(fn -> %{} end)

      try do
        result =
          WikiDump.run(quests,
            fetch: &fetch_quest_sections/1,
            resolve: &resolve_image_urls/1,
            write: fn quest, manifest ->
              manifest = Contributors.merge(manifest, Map.get(rosters, quest.wiki_title))
              Agent.update(agent, &Map.put(&1, quest.normalized_name, manifest))
              :ok
            end
          )

        {Agent.get(agent, & &1), Map.take(result.summary, [:processed, :failed])}
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

  # ── Wiki HTTP (the shared requests live in `EftBuddy.Wiki.Api`) ────

  # Build the section list (incl. the synthesized lead) and fetch each
  # section's wikitext for one quest — identical to the quest sync, so
  # the manifest shape matches `wiki_quests.content` exactly.
  defp fetch_quest_sections(quest) do
    with {:ok, sections_list} <- Api.section_list(quest.wiki_title) do
      sections_list = [%{index: "0", heading: "(lead / infobox)", level: "0"} | sections_list]

      {:ok,
       Enum.map(sections_list, fn s ->
         %{
           index: s.index,
           heading: s.heading,
           level: s.level,
           wikitext: fetch_wikitext_section(quest.wiki_title, s.index)
         }
       end)}
    end
  end

  # A section we can't fetch doesn't fail the whole quest; it is stored empty and
  # counted on the run's `warnings=`.
  defp fetch_wikitext_section(title, section_index) do
    case Api.section_wikitext(title, section_index) do
      {:ok, wikitext} ->
        wikitext

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
    {info, failed} = Api.images_with_licenses(file_titles, "url|size|mime|user")

    if failed > 0,
      do: Reporter.silent_warn("[#{prefix()}] #{failed} image or licence batch(es) failed")

    info
  end

  # Event banners, keyed by the bare filenames the parsed records carry.
  defp resolve_banner_urls(events) do
    {info, failed} =
      events
      |> Enum.map(& &1.banner_filename)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&("File:" <> &1))
      |> Api.imageinfo("url|size|mime|user")

    if failed > 0,
      do: Reporter.silent_warn("[#{prefix()}] #{failed} banner imageinfo batch(es) failed")

    Map.new(info, fn {"File:" <> filename, iinfo} -> {filename, iinfo["url"]} end)
  end

  # Round-trip an atom-keyed manifest/content map through JSON so it's
  # stored string-keyed (exactly what a JSONB read returns), matching
  # `wiki_quests` / `wiki_chapters` and what `EftBuddy.Wiki.Projection`
  # expects at read time.
  defp json_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
end
