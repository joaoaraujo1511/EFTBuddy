defmodule EftBuddy.Wiki.Sync do
  @moduledoc """
  Scrapes quest walkthroughs from the EFT Fandom wiki and upserts them
  into `wiki_quests`. Replaces the old offline `dump_wiki_quests.exs`
  script + committed JSON manifests + boot-time ETS load.

  Scheduled like the other syncers: a background run a short while after
  boot (so the Tasks sync has populated the `tasks` table first), then
  daily. Can also be triggered synchronously from IEx:

      EftBuddy.Wiki.Sync.run()

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
    * empty category enumeration (API down / category renamed) → skip,
      keep existing rows, retry on the normal cadence.
    * a single page that fails to fetch is isolated by
      `EftBuddy.Wiki.Dump.run/2` and its existing row is preserved by the
      prune (the slug is still in the processed set).
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
    interval: 24 * 60 * 60 * 1_000,
    bootstrap: :chained,
    fallback: 45 * 60 * 1_000,
    config_key: :wiki

  require Logger
  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Tasks.Task
  alias EftBuddy.Wiki.{Contributors, Dump, DumpScript, FileLicense, Projection, QuestPage}
  alias EftBuddy.Sync.Reporter

  @api_url "https://escapefromtarkov.fandom.com/api.php"
  @category "Category:Quests"
  @imageinfo_batch 50

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
        titles = enumerate_quest_titles()

        if titles == [] do
          Logger.error(
            "[#{prefix()}] enumerated 0 quests from #{@category} (API down or category renamed?); keeping existing rows."
          )

          {:error, :empty_enumeration}
        else
          titles
          |> Enum.filter(&Dump.quest_title?/1)
          |> blacklist_event_quests()
          |> scrape_and_upsert(db_index)
        end
    end
  end

  # Event quests are owned by `EftBuddy.Events.Sync` and intentionally
  # excluded from this scrape so they stop surfacing as WIP on the Tasks
  # tab (their walkthroughs live on the Events tab instead). Drop any
  # enumerated title whose slug is a known event-quest slug; the prune
  # that follows then deletes any `wiki_quests` rows previously written
  # for them. The events sync is scheduled to run before this one, but if
  # its table isn't populated yet the blacklist is empty and this is a
  # no-op (the quests fall back to WIP until the next cycle).
  defp blacklist_event_quests(titles) do
    blacklist = EftBuddy.Events.blacklisted_quest_slugs()

    if MapSet.size(blacklist) == 0 do
      titles
    else
      Enum.reject(titles, fn title -> MapSet.member?(blacklist, Dump.normalize_name(title)) end)
    end
  end

  defp scrape_and_upsert(titles, db_index) do
    quests = Enum.map(titles, &Dump.build_quest(&1, db_index))

    # Fetched up front for the whole page set so the per-page credits cost
    # a handful of batched requests rather than one request per quest.
    rosters = Contributors.fetch(Enum.map(quests, & &1.wiki_title), http_opts())

    result =
      Dump.run(quests,
        fetch: &fetch_quest_sections/1,
        resolve: &resolve_image_urls/1,
        write: &upsert_quest(&1, &2, rosters)
      )

    # Blacklisted quests (Ref / historical content) were skipped by the
    # fetch and never written, so drop their slugs from the keep-set: the
    # prune below then deletes any rows a previous run wrote for them,
    # clearing them out of the Tasks-tab WIP list.
    blacklisted = MapSet.new(result.skipped, & &1.slug)

    keep_slugs =
      quests
      |> Enum.map(& &1.normalized_name)
      |> Enum.reject(&MapSet.member?(blacklisted, &1))

    pruned = prune(keep_slugs)

    {:ok,
     %{
       processed: result.summary.processed,
       failed: result.summary.failed,
       blacklisted: result.summary.skipped,
       pruned: pruned,
       wip:
         Enum.count(quests, fn q ->
           q.wip and not MapSet.member?(blacklisted, q.normalized_name)
         end)
     }}
  end

  # Delete rows for quests no longer present on the wiki (or now
  # blacklisted). Safe because `keep_slugs` covers every enumerated page
  # we still want — a page whose fetch failed is still in this set, so its
  # prior row is preserved — and we only reach here on a non-empty
  # enumeration. The empty clause guards the pathological "everything got
  # blacklisted" case so it can't `NOT IN ()` the whole table away.
  defp prune([]), do: 0

  defp prune(keep_slugs) do
    {deleted, _} =
      Repo.delete_all(from(q in QuestPage, where: q.normalized_name not in ^keep_slugs))

    deleted
  end

  # ── Injected write: upsert one quest's manifest as a row ───────────

  defp upsert_quest(quest, manifest, rosters) do
    # Round-trip the atom-keyed manifest through JSON so `content` is
    # stored string-keyed (exactly what a JSONB read returns) and the
    # projection/karma parsing below see the same shape as at read time.
    content =
      manifest
      |> Contributors.merge(Map.get(rosters, quest.wiki_title))
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

  # ── Wiki HTTP (impure glue, mirrors the old runner) ────

  defp http_opts, do: [url: @api_url, user_agent: DumpScript.user_agent()]

  defp enumerate_quest_titles do
    DumpScript.enumerate_category_members(@category, http_opts())
  end

  defp fetch_quest_sections(quest) do
    case fetch_sections(quest.wiki_title) do
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
  defp classify_and_fetch(quest, sections_list) do
    lead_wikitext = fetch_wikitext_section(quest.wiki_title, "0")

    case Dump.blacklist_reason(lead_wikitext) do
      nil -> {:ok, [lead_section(lead_wikitext) | fetch_rest_sections(quest, sections_list)]}
      reason -> {:skip, reason}
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

      # A single section we can't fetch shouldn't fail the whole quest;
      # it's swallowed to "" but counted on the run summary so a page
      # that quietly lost a section still shows up as warnings=N.
      {:error, reason} ->
        Reporter.silent_warn(
          "[#{prefix()}] wikitext section #{section_index} of #{title} failed: #{inspect(reason)}"
        )

        ""
    end
  end

  defp resolve_image_urls(file_titles) do
    file_titles
    |> Enum.uniq()
    |> Enum.chunk_every(@imageinfo_batch)
    |> Enum.flat_map(&resolve_image_batch/1)
    |> Map.new()
    |> merge_file_licenses()
  end

  # Only a handful of files on the whole wiki declare a licence of their
  # own; those are the contributor-authored ones we credit. Keys here are
  # already `"File:"`-prefixed titles, which is what FileLicense expects.
  defp merge_file_licenses(info) do
    licenses = FileLicense.fetch(Map.keys(info), http_opts())

    Map.new(info, fn {title, iinfo} ->
      {title, Map.put(iinfo, "license", Map.get(licenses, title))}
    end)
  end

  defp resolve_image_batch(batch) do
    case DumpScript.api_get(
           %{
             "action" => "query",
             "titles" => Enum.join(batch, "|"),
             "prop" => "imageinfo",
             # `url` also returns `descriptionurl` (the File: page), and
             # `user` is the uploader - both needed for the image credit.
             "iiprop" => "url|size|mime|sha1|user|extmetadata",
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
          %{"title" => t, "imageinfo" => [iinfo | _]} -> [{original_for.(t), iinfo}]
          _ -> []
        end)

      {:error, reason} ->
        Reporter.silent_warn("[#{prefix()}] imageinfo batch failed: #{inspect(reason)}")
        []
    end
  end
end
