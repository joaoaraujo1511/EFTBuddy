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

  use GenServer

  require Logger
  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Tasks.Task
  alias EftBuddy.Wiki.{Contributors, Dump, DumpScript, FileLicense, Projection, QuestPage}
  alias EftBuddy.Sync.Reporter

  @api_url "https://escapefromtarkov.fandom.com/api.php"
  @category "Category:Quests"
  @imageinfo_batch 50

  @default_interval 24 * 60 * 60 * 1_000

  @doc false
  # Public so `EftBuddy.Sync.Freshness` can assert its staleness budget covers this
  # cadence rather than trusting a comment to keep the two in step.
  def interval_ms, do: @default_interval

  # The quest scrape is the longest of the three and depends on the events
  # scrape having finished — it reads the `event_quests` blacklist that scrape
  # writes — so rather than a fixed offset it's chained: `EftBuddy.Events.Sync`
  # casts `:events_complete` here when its run finishes, and this scrape starts
  # a short gap later. That guarantees the blacklist is fully populated first
  # (fixing the cold-start race where event quests still showed as WIP) AND
  # that the two heaviest scrapes never hit the Fandom API at once.
  @post_events_gap 1 * 60 * 1_000
  # Fallback only: if the events sync never signals (cold start disabled, or
  # its scrape keeps failing) run anyway after this delay so the quest table
  # can't go stale forever. Generous so it never pre-empts a normal events
  # run, which finishes comfortably within it.
  @fallback_delay 45 * 60 * 1_000
  # When the tasks table isn't populated yet (cold start still running),
  # retry soon rather than waiting a whole day.
  @no_tasks_retry 5 * 60 * 1_000

  @lock_id {__MODULE__, :running}

  @replace_on_conflict [
    :name,
    :task_id,
    :wip,
    :given_by,
    :karma_kind,
    :karma_value,
    :content,
    :updated_at
  ]

  # ── Client ─────────────────────────────────────────────

  # Cluster-wide singleton, same pattern as `Items.Sync`: only one node
  # registers the GenServer; the others :ignore start_link so their
  # supervisor leaves the slot empty rather than every node firing its
  # own daily scrape against the wiki.
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: {:global, __MODULE__}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        Logger.info("[#{prefix()}] Another node already runs the wiki sync; staying idle here.")
        :ignore
    end
  end

  @doc """
  Run the wiki scrape synchronously. Returns `{:ok, summary}`,
  `{:error, :no_tasks}`, `{:error, :empty_enumeration}`,
  `{:error, :already_running}`, or `{:error, reason}`.
  """
  def run, do: with_global_lock(&do_run/0)

  @doc "Trigger a scrape asynchronously (e.g. from IEx)."
  def sync_now, do: GenServer.cast({:global, __MODULE__}, :sync_now)

  # ── Server ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    fallback = Keyword.get(opts, :fallback_delay, @fallback_delay)
    timer = Process.send_after(self(), :sync, fallback + jitter(fallback))
    {:ok, %{interval: interval, timer: timer}}
  end

  @impl true
  def handle_info(:sync, %{interval: interval} = state) do
    next =
      case safe_run() do
        {:error, :no_tasks} -> @no_tasks_retry
        _ -> interval
      end

    timer = Process.send_after(self(), :sync, next + jitter(next))
    {:noreply, %{state | timer: timer}}
  end

  # The events sync finished its run and refreshed the `event_quests`
  # blacklist this scrape honours: (re)arm the scrape a short gap later,
  # cancelling the standing fallback/daily timer. If a scrape is somehow
  # already running, the global lock makes the armed run a no-op.
  @impl true
  def handle_cast(:events_complete, state) do
    {:noreply, arm_first_run(state, @post_events_gap)}
  end

  def handle_cast(:sync_now, state) do
    safe_run()
    {:noreply, state}
  end

  defp arm_first_run(state, offset) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :sync, offset + jitter(offset))
    %{state | timer: timer}
  end

  defp safe_run do
    case run() do
      {:ok, summary} ->
        Logger.info("[#{prefix()}] done: #{inspect(summary)}")
        {:ok, summary}

      {:error, :already_running} ->
        Logger.info("[#{prefix()}] skipped: another wiki sync is already running")
        {:error, :already_running}

      {:error, reason} ->
        Logger.warning("[#{prefix()}] run ended early: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error(
        "[#{prefix()}] crash: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error, {:crash, Exception.message(e)}}
  end

  # ── Pipeline ───────────────────────────────────────────

  defp do_run do
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

  # ── Cluster-wide lock (mirrors Items.Sync / Tasks.Sync) ─

  defp with_global_lock(fun) do
    nodes = [node() | Node.list()]

    case :global.set_lock(@lock_id, nodes, 0) do
      true ->
        try do
          fun.()
        after
          :global.del_lock(@lock_id, nodes)
        end

      false ->
        {:error, :already_running}
    end
  end

  # Colorized module tag for this sync's own log lines (done:/skipped:/
  # crash:/etc.), so they match the coloring of the Reporter summary.
  # Mirrors the Bootstrap orchestrator's `prefix/0`.
  defp prefix, do: Reporter.colorize_label("WikiSync")

  # Spread scheduled ticks so a multi-node rolling restart (or the daily
  # re-run across the cluster) doesn't fire every timer at the same
  # instant. Bounded to ~10% of the interval.
  defp jitter(ms) when is_integer(ms) and ms > 0, do: :rand.uniform(div(ms, 10) + 1)
  defp jitter(_), do: 0
end
