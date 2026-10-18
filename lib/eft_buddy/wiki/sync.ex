defmodule EftBuddy.Wiki.Sync do
  @moduledoc """
  Scrapes quest walkthroughs from the EFT Fandom wiki and upserts them
  into `wiki_quests`. Replaces the old offline `dump_wiki_quests.exs`
  script + committed JSON manifests + boot-time ETS load.

  Runs every six hours, and can also be triggered synchronously from IEx:

      EftBuddy.Wiki.Sync.run()

  ## Chained AND self-timed, which is new

  This scrape reads the `event_quests` blacklist `EftBuddy.Events.Sync` writes,
  so it is armed by that sync completing rather than by a fixed offset. That was
  the whole schedule while both ran daily.

  It now runs at 6h while events runs at 12h, so "a minute after every events
  run" can no longer deliver the cadence. It keeps a real 6h timer, and the
  `:events_complete` cast re-arms it — `arm_first_run/2` cancels and reschedules,
  so a chained run simply replaces the pending self-timed one.

  The FIRST run is neither of those: Bootstrap runs this scrape directly, in the
  cold start, immediately after the events scrape it depends on — which is why
  `bootstrap: :ran` rather than `:chained`. Being chained-only meant the first
  run came from the fallback timer alone, since the cast that would arm it could
  not arrive until the events feed's own first run, hours later. On a fresh
  database that left `wiki_quests` empty for over two hours.

  The consequence is that roughly half the runs use a blacklist up to twelve
  hours old. That is acceptable: the blacklist is a set of event-quest slugs,
  and it changes when an event starts or ends, not continuously. A quest that
  slips through for one cycle shows as WIP on the Tasks tab and is corrected on
  the next.

  ## On the 6h cadence

  This is the heaviest scrape in the app — it enumerates `Category:Quests`, then
  fetches every quest page's lead section and its remaining sections — and it
  points four times the traffic at a third party that already rate-limits with
  503s. Conditional fetching (compare each page's `revid` before pulling
  sections) is the mitigation, and should be treated as required rather than
  optional if the Fandom error rate rises.

  Pipeline (all the pure parts are reused from the dump pipeline so this
  module is only the impure glue):

    1. Load `{id, name, normalized_name}` for every task and build a
       match index (`EftBuddy.Wiki.Dump.build_db_index/1`).
    2. Enumerate `Category:Quests` from the wiki.
    3. For each page, fetch its lead section first and drop it when the
       blacklist trips — a quest given by the trader Ref, or a page
       tagged `{{Historical content}}` ("removed or replaced"). Otherwise
       fetch the remaining sections, parse + assemble a manifest
       (`EftBuddy.Wiki.Dump`), and upsert a `wiki_quests` row — matched
       rows adopt the task's slug + id and `wip: false`; unmatched pages
       are `wip: true` keyed by the wiki slug.
    4. Prune rows for quests that have vanished from the wiki (or are now
       blacklisted), so they also drop off the Tasks-tab WIP list.

  ## Defensiveness

  A scrape that can't see the data it needs must never wipe good rows:

    * empty `tasks` table → skip entirely (every quest would be a
      mis-keyed WIP), retry sooner.
    * a category that cannot be listed whole (a failed continuation page)
      or lists nothing → skip, keep existing rows (`EftBuddy.Wiki.Api`
      enumerates all or nothing; a partial listing used to prune ~40% of the
      table), and the prune itself refuses to drop most of the table.
    * a single page that fails to fetch is isolated by
      `EftBuddy.Wiki.Dump.run/2` and its existing row is preserved by the
      prune (the slug is still in the processed set). A page with a failed
      section, image batch or roster is stored without a revision so it is
      scraped again (`EftBuddy.Wiki.PageGaps`).
    * more than 10% of the attempted pages failing makes the run an error
      (`EftBuddy.Wiki.Api.scrape_result/3`), which `/health/sync` can see.
  """

  # `bootstrap: :chained` — this one is not armed by Bootstrap at all.
  # `EftBuddy.Events.Sync` casts `:events_complete` here when its run finishes
  # and the scrape starts a short gap later, because this scrape reads the
  # `event_quests` blacklist that one writes. Chaining on completion rather than
  # using a fixed offset guarantees the blacklist is fully populated first (it
  # fixed the cold-start race where event quests still showed as WIP) and keeps
  # the two heaviest Fandom scrapes off the API at the same time.
  #
  # The `fallback` is generous so it never pre-empts a normal events run, which
  # finishes comfortably within it. It exists for the case where the events sync
  # never signals at all — cold start disabled, or its scrape failing — so the
  # quest table cannot go stale forever.
  use EftBuddy.Sync.Scheduler,
    label: "WikiSync",
    interval: 6 * 60 * 60 * 1_000,
    stagger: 90 * 60 * 1_000,
    bootstrap: :ran,
    fallback: 45 * 60 * 1_000,
    config_key: :wiki

  require Logger
  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Tasks.Task
  alias EftBuddy.Wiki.{Api, Contributors, Dump, PageGaps, Projection, QuestPage}
  alias EftBuddy.Sync.Reporter

  @category "Category:Quests"

  # What the image lookup asks for: `url` also returns `descriptionurl` (the
  # File: page), and `user` is the uploader, both needed for the image credit.
  @iiprop "url|size|mime|sha1|user|extmetadata"

  # How long after `:events_complete` this scrape starts.
  @post_events_gap 1 * 60 * 1_000

  # When the tasks table isn't populated yet (cold start still running),
  # retry soon rather than waiting a whole day.
  @no_tasks_retry 5 * 60 * 1_000

  @impl EftBuddy.Sync.Scheduler
  # A scrape that found no tasks to attach quests to ran too early — the cold
  # start has not populated the table yet. Coming back in minutes rather than on
  # the normal cadence is the difference between the quest tab being right after
  # boot and being empty for a day.
  def next_interval({:error, :no_tasks}, _interval), do: @no_tasks_retry
  def next_interval({:error, :already_running}, _interval), do: Scheduler.contention_retry_ms()
  def next_interval(_result, interval), do: interval

  @impl EftBuddy.Sync.Scheduler
  # The events sync finished its run and refreshed the `event_quests` blacklist
  # this scrape honours: (re)arm the scrape a short gap later, cancelling the
  # standing fallback/daily timer. If a scrape is somehow already running, the
  # global lock makes the armed run a no-op.
  def handle_extra_cast(:events_complete, state) do
    {:noreply, arm_first_run(state, @post_events_gap)}
  end

  def handle_extra_cast(_msg, state), do: {:noreply, state}

  @replace_on_conflict [
    :name,
    :task_id,
    :wip,
    :given_by,
    :karma_kind,
    :karma_value,
    :banner_url,
    :revision_id,
    :content,
    :updated_at
  ]

  @impl EftBuddy.Sync.Scheduler
  def do_run do
    Reporter.with_run("WikiSync", &run_pipeline/0)
  end

  # The scrape pipeline, run *inside* the Reporter so every query it
  # issues — including the pre-flight `load_db_rows/0` SELECT used for the
  # empty-tasks guard — is folded into the run summary instead of leaking
  # out as a stray Ecto debug line in dev.
  defp run_pipeline do
    db_rows = load_db_rows()

    cond do
      db_rows == [] ->
        Logger.warning(
          "[#{prefix()}] tasks table is empty; skipping scrape so we don't write a table of mis-keyed WIP quests. Will retry shortly."
        )

        {:error, :no_tasks}

      true ->
        db_index = Dump.build_db_index(db_rows)

        case Api.category_members(@category) do
          {:error, reason} ->
            Logger.error(
              "[#{prefix()}] could not enumerate #{@category} (#{inspect(reason)}); keeping existing rows."
            )

            {:error, {:enumeration_failed, reason}}

          {:ok, []} ->
            Logger.error(
              "[#{prefix()}] enumerated 0 quests from #{@category} (category renamed?); keeping existing rows."
            )

            {:error, :empty_enumeration}

          {:ok, titles} ->
            titles
            |> Enum.filter(&Dump.quest_title?/1)
            |> Enum.map(&Dump.build_quest(&1, db_index))
            |> drop_event_only_quests()
            |> scrape_and_upsert()
        end
    end
  end

  # Event quests that tarkov.dev does not serve as tasks are owned by
  # `EftBuddy.Events.Sync`: without this they would surface on the Tasks tab as
  # WIP quests "recently added to the wiki", when their walkthroughs live on the
  # Events tab. Their rows are dropped here, and the prune that follows deletes
  # any a previous run wrote.
  #
  # ONLY the ones that would be WIP. The blacklist used to remove every event-page
  # title, including 24 that tarkov.dev serves as real tasks (Icebreaker: Stick
  # to It, Saving Private Roman, the Labyrinth quests), so their Tasks rows had no
  # guide, objective images or karma requirement (audit H13). A quest matched to
  # a real task is not WIP, so it keeps its wiki guide, keyed by the task's slug,
  # and still appears on the Events tab as well.
  #
  # The events sync runs before this one. If its table isn't populated yet the
  # blacklist is empty and this is a no-op: the quests fall back to WIP until the
  # next cycle.
  defp drop_event_only_quests(quests) do
    blacklist = EftBuddy.Events.blacklisted_quest_slugs()

    Enum.reject(quests, fn quest ->
      quest.wip and MapSet.member?(blacklist, Dump.normalize_name(quest.wiki_title))
    end)
  end

  defp scrape_and_upsert(all_quests) do
    # One batched `prop=revisions` query per fifty pages tells us which pages
    # have actually been edited since we last stored them. Everything else is
    # skipped without fetching a single section.
    revisions = current_revision_ids(all_quests)
    {quests, unchanged} = partition_by_revision(all_quests, revisions)

    log_skipped_unchanged(unchanged, all_quests)

    # Fetched up front for the whole page set so the per-page credits cost
    # a handful of batched requests rather than one request per quest.
    rosters = Contributors.fetch(Enum.map(quests, & &1.wiki_title), Api.http_opts())

    result =
      Dump.run(quests,
        fetch: &fetch_quest_sections/1,
        resolve: &resolve_image_urls/1,
        write: &upsert_quest(&1, &2, rosters, revisions)
      )

    # Blacklisted quests (Ref / historical content) were skipped by the
    # fetch and never written, so drop their slugs from the keep-set: the
    # prune below then deletes any rows a previous run wrote for them,
    # clearing them out of the Tasks-tab WIP list.
    blacklisted = MapSet.new(result.skipped, & &1.slug)

    # UNCHANGED PAGES MUST STAY IN THE KEEP-SET, and this is the sharp edge of
    # the whole optimisation. `prune/1` deletes every row whose slug is absent,
    # so a page skipped because nothing changed looks identical to a page that
    # vanished from the wiki — and the first incremental run would delete most of
    # the table. The keep-set is built from ALL enumerated quests for exactly
    # that reason; only the blacklisted ones are removed from it.
    keep_slugs =
      all_quests
      |> Enum.map(& &1.normalized_name)
      |> Enum.reject(&MapSet.member?(blacklisted, &1))

    pruned = prune(keep_slugs)

    summary = %{
      processed: result.summary.processed,
      unchanged: length(unchanged),
      failed: result.summary.failed,
      # Stored without a revision because part of the page could not be
      # fetched (see `EftBuddy.Wiki.PageGaps`); each is scraped again next run.
      incomplete: Repo.aggregate(from(q in QuestPage, where: is_nil(q.revision_id)), :count),
      blacklisted: result.summary.skipped,
      pruned: pruned,
      wip:
        Enum.count(all_quests, fn q ->
          q.wip and not MapSet.member?(blacklisted, q.normalized_name)
        end)
    }

    Api.scrape_result(
      summary,
      result.summary.processed + result.summary.failed,
      result.summary.failed
    )
  end

  # Split the enumerated quests into "needs scraping" and "unchanged since the
  # last run".
  #
  # A quest is scraped when anything is unknown: no stored row, no stored
  # revision, or no revision reported by the API. Unknown resolves to "scrape it"
  # in every direction, because the cost of a needless scrape is one page fetch
  # and the cost of a wrongly-skipped one is a walkthrough that never updates.
  #
  # It is also scraped when it moved between WIP and matched, edited or not. The
  # row stores more than the page: `task_id` and `wip`, and the sections were
  # parsed for a WIP or a real quest (`Dump.parse_raw_section/2`). Comparing
  # revisions alone kept a quest that tarkov.dev had since added stored as WIP,
  # unmatched, until someone happened to edit its wiki page; 143 rows sat like
  # that in a dev database, every one of them a live task (found verifying audit
  # H13).
  #
  # `wip`, not `task_id`: every quest has one task row per game mode under the
  # same slug, and the index adopts whichever sorts first, so the stored id can
  # be either mode's. Comparing ids re-scraped about half the matched pages on
  # every run.
  @doc false
  # Public so the "unknown means scrape it" rule can be tested directly; the
  # alternative is exercising it through a network call.
  def partition_by_revision(quests, revisions) do
    stored = stored_rows()

    Enum.split_with(quests, fn quest ->
      current = Map.get(revisions, quest.wiki_title)

      case Map.get(stored, quest.normalized_name) do
        {previous, wip} ->
          is_nil(current) or is_nil(previous) or current != previous or wip != quest.wip

        nil ->
          true
      end
    end)
  end

  defp stored_rows do
    Repo.all(from(q in QuestPage, select: {q.normalized_name, {q.revision_id, q.wip}}))
    |> Map.new()
  end

  defp log_skipped_unchanged([], _all), do: :ok

  defp log_skipped_unchanged(unchanged, all) do
    Logger.info(
      "[#{prefix()}] #{length(unchanged)} of #{length(all)} quest pages unedited since the " <>
        "last run; fetching sections for the remaining #{length(all) - length(unchanged)}."
    )
  end

  # `%{wiki_title => revision_id}` for every enumerated page, batched.
  #
  # A failed batch yields nothing rather than raising, which degrades to a full
  # scrape of those pages — the behaviour before conditional fetching existed.
  # Titles are mapped back to the ones we asked about, so a redirected page is
  # not read as "unknown revision" and scraped on every run.
  defp current_revision_ids(quests) do
    {revisions, failed} = quests |> Enum.map(& &1.wiki_title) |> Api.revision_ids()

    if failed > 0 do
      Reporter.silent_warn(
        "[#{prefix()}] #{failed} revision probe batch(es) failed; scraping those pages unconditionally"
      )
    end

    revisions
  end

  # Delete rows for quests no longer present on the wiki (or now
  # blacklisted). `keep_slugs` covers every enumerated page we still want — a
  # page whose fetch failed is still in this set, so its prior row is preserved —
  # and we only reach here on a complete, non-empty enumeration. The empty clause
  # guards the pathological "everything got blacklisted" case so it can't
  # `NOT IN ()` the whole table away, and `Api.prune/2` refuses a prune that
  # would keep too few of the existing rows.
  @doc false
  # Public because it is the destructive step: it deletes every row whose slug is
  # absent from the keep-set, so the keep-set being wrong is how the whole table
  # goes away. Tested directly rather than inferred.
  def prune([]), do: 0

  def prune(keep_slugs), do: Api.prune(QuestPage, keep_slugs)

  # ── Injected write: upsert one quest's manifest as a row ───────────

  defp upsert_quest(quest, manifest, rosters, revisions) do
    roster = Map.get(rosters, quest.wiki_title)
    if roster == :unavailable, do: PageGaps.note(:contributors)

    # Round-trip the atom-keyed manifest through JSON so `content` is
    # stored string-keyed (exactly what a JSONB read returns) and the
    # projection/karma parsing below see the same shape as at read time.
    content =
      manifest
      |> Contributors.merge(roster)
      |> Jason.encode!()
      |> Jason.decode!()

    {karma_kind, karma_value} =
      case Projection.karma_requirement(content) do
        {:gte, n} -> {"gte", n}
        {:lte, n} -> {"lte", n}
        nil -> {nil, nil}
      end

    attrs = %{
      normalized_name: quest.normalized_name,
      name: quest.name,
      task_id: quest.id,
      wip: quest.wip,
      given_by: manifest.given_by,
      karma_kind: karma_kind,
      karma_value: karma_value,
      # Promoted out of `content` so the Tasks list can render it as a row
      # thumbnail. `Projection.project/1` still reads the same file from the
      # manifest for the detail panel; this is the same value, reachable without
      # projecting every page at mount.
      banner_url: banner_url(content),
      revision_id: revision_to_stamp(quest, revisions),
      content: content
    }

    %QuestPage{}
    |> QuestPage.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @replace_on_conflict},
      conflict_target: :normalized_name
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset.errors}
    end
  end

  # Stamped from the SAME probe that decided this page needed scraping, not
  # re-fetched here. A second read could see a newer revision than the one these
  # sections came from, and the row would then claim to be current for an edit it
  # does not contain — skipped on every subsequent run.
  #
  # And only when every part of the page was fetched. A section, image or roster
  # that failed was stored empty, and a stamped revision would make the next runs
  # skip the page until an editor touched it (audit H11). `nil` means "scrape it
  # again", which is what an incomplete page needs.
  defp revision_to_stamp(quest, revisions) do
    case PageGaps.gaps() do
      [] ->
        Map.get(revisions, quest.wiki_title)

      gaps ->
        Reporter.silent_warn(
          "[#{prefix()}] #{quest.wiki_title}: stored without a revision, will retry (#{inspect(gaps)})"
        )

        nil
    end
  end

  # The banner's URL, read off the same string-keyed manifest the projection
  # reads. Deliberately reuses `EftBuddy.Wiki.Projection`'s extraction rather
  # than re-finding the `banner: true` file here — two copies of "which file is
  # the banner" is how the column and the panel end up disagreeing.
  defp banner_url(content) do
    case Projection.project(content) do
      %{banner: %{url: url}} when is_binary(url) -> url
      _ -> nil
    end
  end

  # ── DB read ────────────────────────────────────────────

  defp load_db_rows do
    Repo.all(
      from(t in Task,
        select: %{id: t.id, name: t.name, normalized_name: t.normalized_name},
        order_by: t.normalized_name
      )
    )
  end

  # ── Wiki HTTP (the shared requests live in `EftBuddy.Wiki.Api`) ────

  defp fetch_quest_sections(quest) do
    # Each page is fetched, resolved and written before the next starts, so
    # what failed for this one is recorded from here until `upsert_quest/4`.
    PageGaps.reset()

    case Api.section_list(quest.wiki_title) do
      {:error, reason} -> {:error, reason}
      {:ok, sections_list} -> classify_and_fetch(quest, sections_list)
    end
  end

  # The lead section (index 0) carries both the infobox `given by` and any
  # page-top notice banner, so fetch it FIRST and let the blacklist decide
  # before we spend N more API calls fetching the remaining sections (and
  # a further round resolving their images). Ref quests and pages tagged
  # `{{Historical content}}` ("removed or replaced") are dropped here: the
  # writer is never reached, so no row is upserted, and the prune deletes
  # any row a previous run left behind. Skipping them is what shortens the
  # run.
  #
  # A lead that cannot be fetched fails the page. It carries the infobox (giver,
  # karma, banner), so storing the page without it would store wrong data, and
  # the page's existing row is kept instead.
  defp classify_and_fetch(quest, sections_list) do
    case Api.section_wikitext(quest.wiki_title, "0") do
      {:error, reason} ->
        {:error, {:lead, reason}}

      {:ok, lead_wikitext} ->
        case Dump.blacklist_reason(lead_wikitext) do
          nil -> {:ok, [lead_section(lead_wikitext) | fetch_rest_sections(quest, sections_list)]}
          reason -> {:skip, reason}
        end
    end
  end

  defp lead_section(wikitext) do
    %{index: "0", heading: "(lead / infobox)", level: "0", wikitext: wikitext}
  end

  defp fetch_rest_sections(quest, sections_list) do
    Enum.map(sections_list, fn s ->
      %{
        index: s.index,
        heading: s.heading,
        level: s.level,
        wikitext: fetch_wikitext_section(quest.wiki_title, s.index)
      }
    end)
  end

  # A section we can't fetch doesn't fail the whole quest: it is stored empty,
  # counted on the run's `warnings=`, and noted so the page is not marked current.
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

  # Images with their file licences, keyed by `"File:"` title. A failed batch
  # leaves those images without a url or credit, so it is a gap in the page.
  defp resolve_image_urls(file_titles) do
    {info, failed} = Api.images_with_licenses(file_titles, @iiprop)

    if failed > 0 do
      PageGaps.note({:images, failed})
      Reporter.silent_warn("[#{prefix()}] #{failed} image or licence batch(es) failed")
    end

    info
  end
end
