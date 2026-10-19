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
  alias EftBuddy.Wiki.{Api, Contributors, PageGaps}
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

  @event_quest_replace_on_conflict [
    :name,
    :task_id,
    :position,
    :content,
    :revision_id,
    :updated_at
  ]

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
    {walkthroughs, scrape} = quest_walkthroughs(events)

    # Every parsed event stays in the keep-set even when its row could not be
    # written, so a bad row keeps its previous version rather than being pruned.
    processed_slugs = Enum.map(events, & &1.normalized_name)

    quest_count =
      Enum.reduce(events, 0, fn event, qcount ->
        case upsert_event(event, banner_map, fetched_at) do
          {:ok, row} ->
            upsert_event_quests(row, event, walkthroughs)

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
        scraped: scrape.processed,
        unchanged: scrape.unchanged,
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

  defp upsert_event_quests(%Event{id: event_id}, event, walkthroughs) do
    slugs = Enum.map(event.quests, & &1.slug)

    # Drop quests this event no longer lists (the cross-event prune,
    # `Api.prune(Event, _)`, only deletes rows for whole vanished events).
    Repo.delete_all(
      from(eq in EventQuest,
        where: eq.event_id == ^event_id and eq.normalized_name not in ^slugs
      )
    )

    event.quests
    |> Enum.with_index()
    |> Enum.each(fn {quest, idx} ->
      case upsert_event_quest(event_id, quest, idx, walkthroughs) do
        :ok ->
          :ok

        {:error, errors} ->
          Reporter.silent_warn(
            "[#{prefix()}] event quest #{inspect(quest.name)} not written: #{inspect(errors)}"
          )
      end
    end)
  end

  defp upsert_event_quest(event_id, quest, position, walkthroughs) do
    walkthrough = Map.get(walkthroughs, quest.slug)

    {replace, walkthrough} =
      case walkthrough do
        nil -> {@event_quest_listing_only, %{content: %{}, task_id: nil, revision_id: nil}}
        found -> {@event_quest_replace_on_conflict, found}
      end

    attrs = %{
      event_id: event_id,
      normalized_name: quest.slug,
      name: quest.name,
      task_id: walkthrough.task_id,
      position: position,
      content: walkthrough.content,
      revision_id: walkthrough.revision_id
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

  # Every event quest's walkthrough, as `%{slug => %{content, task_id,
  # revision_id}}` keyed by the Events page's own quest slug, plus
  # `%{processed, failed, unchanged}` counts. A quest absent from the map failed
  # to scrape this run.
  #
  # Only pages edited since their stored revision are scraped (audit M22). The
  # events scrape used to fetch all ~250 quest pages every twelve hours, 14-16
  # minutes and ~1,700 requests per run against a wiki that rate-limits; one
  # batched revision probe per fifty pages now decides, as in `EftBuddy.Wiki.Sync`.
  # Unknown resolves to "scrape it" in every direction: no stored revision, or
  # none reported by the API. A quest that moved between WIP and matched since
  # it was stored is scraped too, edited or not: the walkthrough was parsed for
  # one or the other, as in `EftBuddy.Wiki.Sync.partition_by_revision/2`.
  defp quest_walkthroughs(events) do
    quest_titles = EventsDump.unique_quest_titles(events)

    if quest_titles == [] do
      {%{}, %{processed: 0, failed: 0, unchanged: 0}}
    else
      {revisions, failed_probes} = quest_titles |> Enum.map(& &1.wiki_title) |> Api.revision_ids()

      if failed_probes > 0 do
        Reporter.silent_warn(
          "[#{prefix()}] #{failed_probes} revision probe batch(es) failed; scraping those pages"
        )
      end

      stored = stored_walkthroughs()
      db_index = WikiDump.build_db_index(load_db_rows())

      {changed, unchanged} =
        Enum.split_with(quest_titles, fn q ->
          current = revisions[q.wiki_title]
          previous = stored[q.slug]

          is_nil(current) or is_nil(previous) or previous.revision_id != current or
            Map.get(previous.content, "wip") != WikiDump.build_quest(q.wiki_title, db_index).wip
        end)

      kept = Map.new(unchanged, &{&1.slug, stored[&1.slug]})
      {scraped, counts} = scrape_quest_pages(changed, revisions, db_index)

      {Map.merge(kept, scraped), Map.put(counts, :unchanged, length(unchanged))}
    end
  end

  # One stored walkthrough per quest slug. Only rows with a revision qualify:
  # a revision is stamped only on a complete scrape, so its content is whole.
  defp stored_walkthroughs do
    from(eq in EventQuest,
      where: not is_nil(eq.revision_id),
      select:
        {eq.normalized_name,
         %{content: eq.content, task_id: eq.task_id, revision_id: eq.revision_id}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Scrape `quest_titles` through the SAME `EftBuddy.Wiki.Dump` pipeline the
  # quest sync uses. The injected `write` accumulates into an Agent rather than
  # persisting, so the one walkthrough can be fanned out to every (event, quest)
  # row afterwards.
  defp scrape_quest_pages([], _revisions, _db_index), do: {%{}, %{processed: 0, failed: 0}}

  defp scrape_quest_pages(quest_titles, revisions, db_index) do
    slug_for = Map.new(quest_titles, &{&1.wiki_title, &1.slug})
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
            walkthrough = walkthrough(quest, manifest, rosters, revisions)
            Agent.update(agent, &Map.put(&1, slug_for[quest.wiki_title], walkthrough))
            :ok
          end
        )

      {Agent.get(agent, & &1), Map.take(result.summary, [:processed, :failed])}
    after
      Agent.stop(agent)
    end
  end

  # The revision is stamped only when every part of the page was fetched, as in
  # `EftBuddy.Wiki.Sync` (audit H11): a page with a gap would otherwise be
  # skipped, incomplete, until an editor touched it.
  defp walkthrough(quest, manifest, rosters, revisions) do
    roster = Map.get(rosters, quest.wiki_title)
    if roster == :unavailable, do: PageGaps.note(:contributors)

    revision_id =
      case PageGaps.gaps() do
        [] ->
          revisions[quest.wiki_title]

        gaps ->
          Reporter.silent_warn(
            "[#{prefix()}] #{quest.wiki_title}: stored without a revision, will retry (#{inspect(gaps)})"
          )

          nil
      end

    %{
      content: manifest |> Contributors.merge(roster) |> json_round_trip(),
      task_id: Map.get(manifest, :task_id),
      revision_id: revision_id
    }
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
    # What fails for this page is recorded from here until `walkthrough/4`.
    PageGaps.reset()

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
        PageGaps.note({:section, section_index})

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

    if failed > 0 do
      PageGaps.note({:images, failed})
      Reporter.silent_warn("[#{prefix()}] #{failed} image or licence batch(es) failed")
    end

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
