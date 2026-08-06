defmodule EftBuddyWeb.TasksLive.Index do
  use EftBuddyWeb, :live_view

  alias EftBuddy.Progress
  alias EftBuddy.Tasks
  alias EftBuddy.Wiki
  alias EftBuddy.Wiki.Slug
  alias EftBuddyWeb.ClientBridge

  @page_size 50
  # Visible filter tabs plus `wip` - a hidden filter reachable only via
  # `/tasks?status=wip` (no tab renders for it). Included here so `parse_filter`
  # accepts the slug; when active, the ALL tab stays highlighted (see the
  # template's `active=` guard) so nothing looks broken.
  @valid_filters ~w(all watchlist available locked completed kappa lightkeeper wip)a

  # Keys (inside the ACTIVE GAME MODE's slice of the progress blob) this page
  # owns: the completed-task set and the watchlist. Read from `@client_state` in
  # `mount/3`, written on every toggle via `ClientBridge.put_progress/2`. Both
  # store stable `normalized_name` slugs (not DB UUIDs) so a reseed never orphans
  # saved progress.
  #
  # The watchlist used to be shared across modes, on the reasoning that a quest
  # you're watching is interesting in both. In practice PVP and PVE are separate
  # playthroughs at different stages, so a shared list mixed two backlogs
  # together; it's namespaced per mode now like everything else the operator can
  # change. See `EftBuddy.Progress`.
  @completed_key "completed_tasks"
  @watchlist_key "tasks_watchlist"

  @impl true
  def mount(_params, _session, socket) do
    # Full task set, loaded once. ~600 rows post-dailies-filter is
    # well within the "keep it all in memory" zone, and lets every
    # filter change be a synchronous slice instead of a re-query.
    # The faction filter (driven by the sidebar's @faction assign)
    # and the level-gating (driven by @pmc_level) are both evaluated
    # against this in-memory list every time `reset_pagination/1`
    # runs. OperatorState `:halt`s the underlying events so we don't
    # see them as `handle_event/3` calls; instead it pings us with
    # `{:sidebar_state_changed, key, value}` and the matching
    # `handle_info` clause below kicks off the reflow.
    # The visible list is the union of two sources, resolved DB-first:
    #
    #   * every DB task (API-backed, the fully-supported path), plus
    #   * every wiki manifest whose slug ISN'T backed by a DB task -
    #     surfaced as a WIP quest rendered from wiki data alone.
    #
    # Dedup is presence-based on the slug: the moment a quest exists in
    # the DB it wins, so a quest auto-upgrades from WIP to API-backed
    # the next time the page loads after a Tasks.Sync - no re-dump
    # needed. `wip_view_models/1` already drops anything in `db_slugs`.
    #
    # `db_slugs` is the union of each task's API `normalized_name` AND a
    # slug derived from its NAME (via the same `Slug.normalize_name/1`
    # the dump uses). tarkov.dev's normalizedName deletes apostrophes and
    # appends faction/edition/dedup suffixes (e.g. "Developer's Secrets -
    # Part 1" → "developers-secrets-part-1", "Drip-Out - Part 1" →
    # "drip-out-part-1-bear"), so a wiki page's own slug
    # ("developer-s-secrets-part-1", "drip-out-part-1") matches the API
    # slug for neither - but DOES match the name slug. Including the name
    # slug here stops those quests being shown twice (API-backed + WIP
    # duplicate) even before the dump is re-run.
    socket =
      socket
      |> assign(:page_title, "Tasks")
      |> assign(
        :page_description,
        "Track every Escape from Tarkov quest by trader and status. Availability follows your PMC level, faction and game mode."
      )
      |> assign(:active, :tasks)
      |> assign(:active_trader, "All")
      |> assign(:query, "")
      |> assign(:filter, :all)
      |> assign(:sort, :default)
      |> assign(:filter_counts, %{
        all: 0,
        watchlist: 0,
        available: 0,
        locked: 0,
        completed: 0,
        wip: 0,
        kappa: 0,
        lightkeeper: 0
      })
      # The operator's completed quests, as stable `normalized_name` slugs.
      # This is the CANONICAL set - what gets persisted, verbatim, exactly like
      # `:watchlist_slugs` below.
      #
      # It is deliberately not derived from `:all_tasks`. It used to be: the
      # persisted list was regenerated on every toggle by filtering the current
      # catalogue, which made the saved record an inner join of the operator's
      # data with whatever the sync last wrote. `Tasks.Sync` carries
      # `:normalized_name` in its upsert `replace` list, so an upstream rename
      # (tarkov.dev re-tags quests with `[PVE ZONE]` during events - see
      # `task_dedup_slugs/1`) MUTATES the slug on the existing row. The saved
      # slug then matched nothing, dropped out of the join, and the operator's
      # next unrelated click wrote the shortened list over `localStorage` - the
      # only durable copy. Keeping the slugs and deriving the ids means an
      # unresolvable slug simply sits there until its quest comes back.
      |> assign(:completed_slugs, MapSet.new())
      # Derived from `:completed_slugs` against `:all_tasks`, for rendering and
      # status computation only (`compute_status/6`, `prereqs_met?/3`). Never
      # persisted.
      |> assign(:completed_ids, MapSet.new())
      # The operator's task watchlist - a set of stable `normalized_name`
      # slugs. Hydrated from `@client_state` (the server-authoritative progress
      # blob) by `hydrate_progress/1` below, so it is already correct in the
      # FIRST render on every navigation. Only a cold connect - where the
      # browser still has to hand up its localStorage - arrives later, via
      # `{:client_state_restored, ...}`.
      |> assign(:watchlist_slugs, MapSet.new())
      |> assign(:page_size, @page_size)
      # Expansion state. Mirrors the items_live pattern: each row
      # carries an `:expanded?` flag in its stream entry; clicking
      # the row flips it and lazy-loads the full preloaded task plus
      # its wiki manifest, both cached for the lifetime of the
      # LiveView. Multiple rows can be open simultaneously.
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:details_cache, %{})
      # Scav karma is owned by the operator panel (EftBuddyWeb.OperatorState
      # assigns :scav_karma on every LiveView and persists it). We read it
      # here to gate the Compensation-for-Damage (karma ≤ threshold) and
      # Establish-Contact (karma ≥ threshold) chains; the wiki dump's parsed
      # Requirements text is the only source for those gates.
      # NOTE: `:client_state` (the progress blob) is assigned by the
      # `EftBuddyWeb.OperatorState` on_mount hook, which reads it from the
      # operator's server-side session - so it is available here, in mount,
      # before the first render. Don't re-assign it to `%{}`.
      |> load_task_data()
      |> hydrate_progress()

    {:ok, socket}
  end

  # Derive everything this page owns from the progress blob: the watchlist and
  # the active mode's completion set. Called in `mount/3` (where the blob is
  # already present for any live navigation) and again whenever the blob
  # changes - a cold-boot restore, or another tab editing it.
  defp hydrate_progress(socket) do
    socket
    |> then(&assign(&1, :watchlist_slugs, read_watchlist_slugs(&1)))
    |> apply_progress_from_client_state()
  end

  # Heavy data load - guarded to the connected mount only. The
  # disconnected (static) HTTP render gets empty placeholders, so the
  # ~600-row task load plus the wiki/karma/trader queries run once (on
  # the WebSocket mount) instead of twice. `handle_params/3` runs after
  # both mounts and rebuilds the visible list from whatever `:all_tasks`
  # holds, so the page renders empty for a blink and then fills in.
  defp load_task_data(socket) do
    if connected?(socket) do
      # The active game mode (PVP/PVE) scopes the task set: PVE is a
      # distinct quest graph. Reloaded whenever the sidebar mode flips.
      game_mode = socket.assigns.mode
      db_tasks = Tasks.list_tasks(preloads: [:trader], game_mode: game_mode)

      # The wiki quest set, fetched ONCE and used for both jobs below: deciding
      # which tasks carry a `has_wiki?` badge, and building the WIP rows for the
      # wiki quests no DB task backs.
      #
      # It is hoisted above `db_vms` deliberately. `has_wiki?` used to be a
      # `Wiki.has_wiki?/1` call per task - a `Repo.exists?` round trip, 1-3 of
      # them per row via `wiki_lookup_slugs/1` - so a ~600-task mount issued
      # 600-1200 sequential queries against a pool of 10. The comment justifying
      # it described an ETS-backed wiki layer, which this app has not had since
      # `EftBuddy.Wiki` moved to Postgres (see its moduledoc). `all_quests/0`
      # already selects `normalized_name` for every wiki row unfiltered, so a
      # MapSet membership test is exactly equivalent to the existence check and
      # costs nothing extra - the query was already being made, just afterwards.
      wiki_quests = Wiki.all_quests()
      wiki_slugs = MapSet.new(wiki_quests, & &1.normalized_name)

      db_slugs =
        db_tasks
        |> Enum.flat_map(&task_dedup_slugs/1)
        |> MapSet.new()

      db_vms = Enum.map(db_tasks, &to_view_model(&1, wiki_slugs))
      wip_vms = wip_view_models(wiki_quests, db_slugs)

      socket
      |> assign(:traders, build_trader_chip_list(wip_vms))
      |> assign(:all_tasks, db_vms ++ wip_vms)
      |> assign(:prereq_map, Tasks.prereq_map(game_mode))
      |> assign(:karma_requirements, Wiki.karma_requirements())
    else
      socket
      |> assign(:traders, ["All"])
      |> assign(:all_tasks, [])
      |> assign(:prereq_map, %{})
      |> assign(:karma_requirements, %{})
    end
  end

  # ── URL-driven filter state ────────────────────────────

  @impl true
  # Read `?status=`, `?trader=`, and `?q=` from the URL into the
  # corresponding assigns. The options-bar tabs and trader filter-bar
  # chips are `<.link patch={...}>` links, so navigating between them
  # flows through here. That keeps the active filter shareable /
  # bookmarkable / refresh-safe - industry-standard practice for any
  # page where the user can narrow the view.
  #
  # `q` is intentionally clamped to 200 chars so a hostile URL can't
  # bloat the assigns with megabytes of input.
  def handle_params(params, _uri, socket) do
    status = parse_filter(params["status"])

    trader =
      params
      |> Map.get("trader")
      |> resolve_trader(socket.assigns.traders)

    query =
      params
      |> Map.get("q", "")
      |> to_string()
      |> String.slice(0, 200)

    socket =
      socket
      |> assign(:filter, status)
      |> assign(:active_trader, trader)
      |> assign(:query, query)
      |> reset_pagination()

    {:noreply, socket}
  end

  # ── Events ─────────────────────────────────────────────

  # The search input fires `phx-change` on every keystroke (debounced
  # in the template). We patch the URL so refreshing or sharing the
  # link preserves the search; `handle_params/3` then reflows the
  # filtered list. `replace: true` keeps the browser history clean -
  # nobody wants 30 entries for "g", "ge", "gea", "gear".
  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: tasks_path(query, socket.assigns.active_trader, socket.assigns.filter),
       replace: true
     )}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: tasks_path("", socket.assigns.active_trader, socket.assigns.filter),
       replace: true
     )}
  end

  # Per-row checkbox toggles completion. The row id is resolved to the quest's
  # stable slug and THAT is what moves in `:completed_slugs`, the canonical set
  # `persist_tasks_progress/1` writes to localStorage. `:completed_ids` is then
  # re-derived, because the Available/Locked/Completed chip, the Available and
  # Completed filters and `prereqs_met?/3` all read ids.
  #
  # An id that resolves to nothing is a no-op rather than a crash: the row must
  # be in `:all_tasks` for the operator to have clicked it, so a miss means a
  # forged or replayed event.
  def handle_event("toggle_complete", %{"id" => task_id}, socket) do
    case Enum.find(socket.assigns.all_tasks, &(&1.id == task_id)) do
      nil ->
        {:noreply, socket}

      task ->
        slugs = socket.assigns.completed_slugs
        slug = task.normalized_name

        new_slugs =
          if MapSet.member?(slugs, slug),
            do: MapSet.delete(slugs, slug),
            else: MapSet.put(slugs, slug)

        {:noreply,
         socket
         |> assign_completed(new_slugs)
         |> persist_tasks_progress()
         |> reset_pagination()}
    end
  end

  def handle_event("toggle_complete", _params, socket), do: {:noreply, socket}

  # Add/remove a quest from the operator's watchlist. The star is flipped
  # instantly client-side (paired `JS.toggle_class`), so here we update the
  # canonical slug set, persist it to localStorage via the `Hud` hook, and
  # reflow the list - a watchlisted quest sorts to the very top (see
  # `sort_tasks/1`). Keyed by the stable `normalized_name` slug, like the
  # completed set, so a reseed never orphans a saved watchlist.
  def handle_event("toggle_watchlist", %{"slug" => slug}, socket)
      when is_binary(slug) and slug != "" do
    slugs = socket.assigns.watchlist_slugs

    new_slugs =
      if MapSet.member?(slugs, slug),
        do: MapSet.delete(slugs, slug),
        else: MapSet.put(slugs, slug)

    {:noreply,
     socket
     |> assign(:watchlist_slugs, new_slugs)
     |> persist_watchlist()
     |> reset_pagination()}
  end

  def handle_event("toggle_watchlist", _params, socket), do: {:noreply, socket}

  # Toggle expansion of a single row. Lazy-loads the full preloaded
  # task and the wiki manifest the first time a row opens; both are
  # cached in `:details_cache` so reopening is instant. Stream-based
  # update so only the affected row re-renders.
  #
  # The cache lives only for the lifetime of this LiveView process -
  # we deliberately don't try to share it across users. The "miss" path is
  # NOT cheap: it is a preload-heavy `Tasks.get_task_details/1` plus a
  # `Wiki.get_quest/1` read, all of it Postgres. It runs on an explicit
  # user click and is memoised for the rest of the session, which is what
  # makes that acceptable - not a cache layer underneath it.
  def handle_event("toggle_expand", %{"id" => task_id}, socket) do
    %{expanded_ids: expanded, details_cache: cache, filtered_tasks: filtered_tasks} =
      socket.assigns

    if MapSet.member?(expanded, task_id) do
      new_expanded = MapSet.delete(expanded, task_id)

      socket =
        socket
        |> assign(:expanded_ids, new_expanded)
        |> stream_insert(
          :tasks,
          row_with_expansion(task_id, filtered_tasks, cache, new_expanded)
        )

      {:noreply, socket}
    else
      {details, new_cache} =
        case Map.fetch(cache, task_id) do
          {:ok, cached} -> {cached, cache}
          :error -> load_details(Enum.find(filtered_tasks, &(&1.id == task_id)), cache)
        end

      new_expanded = MapSet.put(expanded, task_id)

      socket =
        socket
        |> assign(:expanded_ids, new_expanded)
        |> assign(:details_cache, new_cache)
        |> stream_insert(
          :tasks,
          row_with_expansion(task_id, filtered_tasks, new_cache, new_expanded, details)
        )

      {:noreply, socket}
    end
  end

  # Infinite scroll: append the next slice from the already-filtered
  # in-memory list when the viewport bottom hits.
  def handle_event("load_more", _params, socket) do
    %{
      filtered_tasks: filtered,
      page_size: page_size,
      tasks_loaded: tasks_loaded
    } = socket.assigns

    next_page = Enum.slice(filtered, tasks_loaded, page_size)
    new_total = tasks_loaded + length(next_page)

    {:noreply,
     socket
     |> stream(:tasks, next_page)
     |> assign(:tasks_loaded, new_total)
     |> assign(:end_of_tasks?, new_total >= length(filtered))}
  end

  # Toggle sorting by clicking a sortable column header (Task, Trader or
  # Level). The
  # shared `UI.next_sort/2` cycles each column through three states: unsorted
  # (`:default`, status-first) → ascending → descending → back to unsorted.
  # Only one column is active at a time; clicking a different column starts it
  # at ascending. Watchlisted quests stay pinned to the top in every state (see
  # `sort_tasks/2`). Sort lives only in the socket (not the URL).
  def handle_event("toggle_sort", %{"col" => col}, socket) do
    {:noreply, socket |> assign(:sort, next_sort(col, socket.assigns.sort)) |> reset_pagination()}
  end

  # ── Sidebar reactions ──────────────────────────────────

  # `EftBuddyWeb.OperatorState` `:halt`s the underlying `phx-click`
  # events (it owns the assigns), so the page's own `handle_event/3`
  # never sees `set_faction` / `set_mode` / `pmc_level_inc|dec`. Instead
  # OperatorState sends `{:sidebar_state_changed, key, value}` to
  # `self()` after each change. We catch the keys that affect the
  # visible task list - faction (USEC/BEAR scoping), pmc_level
  # (level-gated → locked/available), mode (cosmetic for now, but
  # may gate tasks once PVE-specific behaviour lands) - and
  # recompute pagination so the list reflows immediately.
  #
  # Pure chrome prefs (e.g. `rail_collapsed`) are deliberately NOT
  # announced on this channel, since no page filters on them.
  # A `:mode` (PVP/PVE) flip is special: it swaps the entire task set AND every
  # slice of progress, because PVE is a separate quest graph tracked separately.
  # We reload the mode's tasks, re-derive ALL of the mode's progress from the
  # cached localStorage blob - `hydrate_progress/1`, so the watchlist swaps with
  # the completion set rather than lingering from the previous mode - then reflow.
  @impl true
  def handle_info({:sidebar_state_changed, :mode, _value}, socket) do
    {:noreply,
     socket
     |> load_task_data()
     |> hydrate_progress()
     |> reset_pagination()}
  end

  # Faction / PMC level / scav karma only change which tasks are visible /
  # how they're gated, not the underlying set or progress - a reflow is
  # enough. Karma is owned by OperatorState, which pings us on change.
  def handle_info({:sidebar_state_changed, key, _value}, socket)
      when key in [:faction, :pmc_level, :scav_karma] do
    {:noreply, reset_pagination(socket)}
  end

  def handle_info({:sidebar_state_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  # The progress blob changed underneath us. Two cases reach here now:
  #
  #   * a COLD connect, where the browser hands up its localStorage for the
  #     first time (`EftBuddyWeb.ClientBridge`), and
  #   * another tab of the same operator editing its progress, fanned out by
  #     `EftBuddy.OperatorSession`.
  #
  # On a live navigation the blob is already in `mount/3`, so this no longer
  # fires there - which is what removed the "watchlist pops in a beat later"
  # flash. Everything is defensively parsed: a missing or malformed field just
  # keeps the current default.
  #
  # Completed tasks are persisted by `normalized_name` slug (not the DB
  # UUID) for the same reason the wiki/karma tables are slug-keyed: a
  # `mix ecto.reset` regenerates task UUIDs, so a UUID saved in a
  # visitor's browser would orphan after a reseed, silently wiping their
  # progress. Slugs are stable across reseeds and redeploys. The slug set
  # is held as-is in `:completed_slugs` and ids are derived from it for the
  # in-memory completion/prereq logic (where `prereq_map` is keyed) - the
  # derivation is one-way, so a slug the current catalogue cannot resolve is
  # carried rather than pruned.
  def handle_info({:client_state_restored, state}, socket) when is_map(state) do
    {:noreply,
     socket
     |> assign(:client_state, state)
     |> hydrate_progress()
     |> reset_pagination()}
  end

  # Derive the in-memory completion set for the ACTIVE game mode from the
  # cached localStorage blob. Every slice of progress is namespaced per mode
  # (see `EftBuddy.Progress`), so PVP and PVE track separately. Scav karma is NOT
  # read here - it's an operator pref, owned by OperatorState (and itself
  # per-mode now).
  defp apply_progress_from_client_state(socket) do
    slugs =
      case Progress.get(socket.assigns.client_state, socket.assigns.mode, @completed_key) do
        list when is_list(list) ->
          list |> Enum.filter(&(is_binary(&1) and &1 != "")) |> MapSet.new()

        _ ->
          MapSet.new()
      end

    assign_completed(socket, slugs)
  end

  # ── Completion set ─────────────────────────────────────
  #
  # `:completed_slugs` is canonical and persisted verbatim. `:completed_ids` is
  # a projection of it onto the current catalogue, kept because the completion
  # set is consulted in-memory by row id (DB UUID for API-backed quests, the
  # slug itself for WIP quests) so it lines up with `prereq_map`.
  #
  # The projection is deliberately ONE-WAY. A slug the current `all_tasks`
  # cannot resolve - a quest renamed upstream, or one absent from the active
  # game mode - contributes no id and simply stays in the canonical set. It
  # costs nothing, renders as nothing, and comes back the moment its quest
  # does.

  # Set the canonical slug set and re-derive the id projection from it.
  defp assign_completed(socket, slugs) do
    socket
    |> assign(:completed_slugs, slugs)
    |> assign(:completed_ids, slugs_to_completed_ids(slugs, socket.assigns.all_tasks))
  end

  # Persist the tasks-progress slice. `ClientBridge.put_progress/2` merges it
  # into the operator's authoritative session AND writes it through to
  # localStorage, returning a socket whose `:client_state` already reflects the
  # write - so an immediate mode flip re-derives from current data without a
  # browser round-trip. Only the completed-task set (stored as stable slugs) is
  # owned here; scav karma is an operator pref (see `EftBuddyWeb.OperatorState`).
  #
  # Writes the canonical set as-is. It must NOT be regenerated from `all_tasks`
  # here: `localStorage` is the only durable copy of this data, so anything the
  # current catalogue happens not to resolve would be permanently deleted by an
  # unrelated toggle. See the note on `:completed_slugs` in `mount/3`.
  defp persist_tasks_progress(socket) do
    ClientBridge.put_progress(socket, %{
      @completed_key => MapSet.to_list(socket.assigns.completed_slugs)
    })
  end

  # Persist the task watchlist (a flat list of stable slugs).
  defp persist_watchlist(socket) do
    ClientBridge.put_progress(socket, %{
      @watchlist_key => MapSet.to_list(socket.assigns.watchlist_slugs)
    })
  end

  # Pull the active game mode's persisted watchlist out of the localStorage blob,
  # defensively: a missing / malformed entry yields an empty set rather than
  # crashing the restore.
  defp read_watchlist_slugs(%{assigns: %{client_state: state, mode: mode}}) do
    case Progress.get(state, mode, @watchlist_key) do
      list when is_list(list) ->
        list |> Enum.filter(&(is_binary(&1) and &1 != "")) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # slugs (canonical) → ids (in-memory projection). One-way by design; there is
  # deliberately no inverse, because regenerating the persisted list from
  # `all_tasks` is what silently deleted renamed quests from the operator's only
  # durable copy. See `assign_completed/2`.
  defp slugs_to_completed_ids(slugs, all_tasks) do
    all_tasks
    |> Enum.filter(&MapSet.member?(slugs, &1.normalized_name))
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  # ── URL helpers ────────────────────────────────────────

  @doc """
  Build a `/tasks` path with the given filter triplet preserved as
  query params. Used by both the options bar (status tabs) and the
  filter bar (trader chips) so clicking one filter never resets the
  others - every link carries the *current* state of the other two
  filters along with whatever it's changing.

  The default values (`""` query, `"All"` trader, `:all` status) are
  omitted from the URL so the bare `/tasks` URL stays clean when no
  filters are active.
  """
  def tasks_path(query, trader, status) do
    params =
      []
      |> maybe_put(:status, status_param(status))
      |> maybe_put(:trader, trader_param(trader))
      |> maybe_put(:q, query_param(query))

    case params do
      [] -> "/tasks"
      _ -> "/tasks?" <> URI.encode_query(params)
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, value}]

  defp status_param(:all), do: nil
  defp status_param(status) when is_atom(status), do: Atom.to_string(status)
  defp status_param(status) when is_binary(status), do: status
  defp status_param(_), do: nil

  defp trader_param("All"), do: nil
  defp trader_param(nil), do: nil
  defp trader_param(""), do: nil
  defp trader_param(name) when is_binary(name), do: name

  defp query_param(""), do: nil
  defp query_param(nil), do: nil
  defp query_param(q) when is_binary(q), do: q

  # When the URL says `?trader=Prapor`, snap to the canonical chip
  # label as it appears in `@traders` (so "All", "Prapor", etc match
  # exactly). Unknown / missing values fall back to "All". This both
  # cleans up arbitrary URL casing and protects the `aria-pressed`
  # comparison from drift.
  defp resolve_trader(nil, _traders), do: "All"
  defp resolve_trader("", _traders), do: "All"

  defp resolve_trader(name, traders) when is_binary(name) do
    needle = String.downcase(name)

    Enum.find(traders, "All", fn chip ->
      String.downcase(chip) == needle
    end)
  end

  # ── Filter / pagination ────────────────────────────────

  # Recompute the filtered list from scratch and reset the stream to
  # the first page. Called from `handle_params/3` (every filter change)
  # and from `toggle_complete` (which can flip a task between
  # available/locked/completed and so changes the visible list).
  #
  # Clearing `:expanded_ids` here matches the items_live pattern:
  # rebuilding the stream from `:filtered_tasks` produces
  # rows without an `:expanded?` flag, so any state we left in the
  # MapSet would drift from what the user actually sees. Cache stays
  # warm so reopening is instant.
  defp reset_pagination(socket) do
    # Compute the trader/faction/search-filtered list with per-task
    # status once, then derive BOTH the per-status counts (for the
    # options-bar badges) and the status-filtered visible list from it,
    # so the counts always reflect the current trader/search context.
    statused = statused_tasks(socket)

    filtered =
      statused
      |> Enum.filter(&filter_match?(&1, socket.assigns.filter))
      |> sort_tasks(socket.assigns.sort)

    first_page = Enum.take(filtered, @page_size)

    socket
    |> assign(:filter_counts, filter_counts(statused))
    |> assign(:filtered_tasks, filtered)
    |> assign(:expanded_ids, MapSet.new())
    |> stream(:tasks, first_page, reset: true)
    |> assign(:tasks_loaded, length(first_page))
    |> assign(:end_of_tasks?, length(first_page) >= length(filtered))
  end

  # Per-status counts for the options-bar badges. Reflects the active
  # trader/faction/search context (computed from the same `statused`
  # list the visible list is sliced from) but NOT the status filter
  # itself, so each tab shows how many tasks it *would* reveal.
  defp filter_counts(statused) do
    base = %{
      all: length(statused),
      watchlist: 0,
      available: 0,
      locked: 0,
      completed: 0,
      wip: 0,
      kappa: 0,
      lightkeeper: 0
    }

    Enum.reduce(statused, base, fn t, acc ->
      acc = Map.update(acc, t.status, 0, &(&1 + 1))
      acc = if Map.get(t, :kappa?), do: Map.update!(acc, :kappa, &(&1 + 1)), else: acc
      acc = if Map.get(t, :watchlisted?), do: Map.update!(acc, :watchlist, &(&1 + 1)), else: acc
      if Map.get(t, :lightkeeper?), do: Map.update!(acc, :lightkeeper, &(&1 + 1)), else: acc
    end)
  end

  # The big filter pipeline. Each step prunes the list further:
  #   trader chip  → faction (sidebar) → search query → status filter
  # We materialize the per-task status once here so the template can
  # render the chip without recomputing.
  defp statused_tasks(socket) do
    %{
      all_tasks: all_tasks,
      active_trader: active_trader,
      query: query,
      faction: faction,
      pmc_level: pmc_level,
      completed_ids: completed_ids,
      prereq_map: prereq_map,
      scav_karma: scav_karma,
      karma_requirements: karma_requirements,
      watchlist_slugs: watchlist_slugs
    } = socket.assigns

    trader_slug =
      case active_trader do
        "All" -> nil
        name -> normalize_trader(name)
      end

    needle = query |> String.trim() |> String.downcase()

    all_tasks
    |> Stream.filter(&trader_match?(&1, trader_slug, faction))
    |> Stream.filter(&faction_match?(&1, faction))
    |> Stream.filter(&search_match?(&1, needle))
    |> Stream.map(fn task ->
      task
      |> Map.put(
        :status,
        compute_status(task, pmc_level, completed_ids, prereq_map, scav_karma, karma_requirements)
      )
      |> Map.put(:watchlisted?, MapSet.member?(watchlist_slugs, task.normalized_name))
    end)
    |> Enum.to_list()
  end

  # Order the visible list. Watchlisted quests always rise to the very top
  # (regardless of status or sort mode); within that, the chosen sort decides:
  #
  #   * `:default`    - status-first (Available → Locked → Completed → WIP),
  #                     alphabetical within each bucket. AVAILABLE rising to
  #                     the top means a quest that just unlocked bubbles into
  #                     the first viewport instead of hiding down an
  #                     alphabetical list.
  #   * `:name_asc`   - quest name A → Z.
  #   * `:name_desc`  - quest name Z → A.
  #   * `:trader_asc` / `:trader_desc` - grouped by trader name.
  #   * `:level_asc`  - required PMC level low → high.
  #   * `:level_desc` - required PMC level high → low.
  #
  # WIP quests (no known level) always sort last in the two level modes, in
  # both directions, so they never masquerade as "level 0" quests.
  defp sort_tasks(tasks, :level_asc) do
    Enum.sort_by(tasks, fn t ->
      {watchlist_sort_key(t), level_present_rank(t), level_value(t), String.downcase(t.name)}
    end)
  end

  defp sort_tasks(tasks, :level_desc) do
    Enum.sort_by(tasks, fn t ->
      {watchlist_sort_key(t), level_present_rank(t), -level_value(t), String.downcase(t.name)}
    end)
  end

  defp sort_tasks(tasks, :trader_asc), do: sort_grouped(tasks, &trader_sort_key/1, :asc)
  defp sort_tasks(tasks, :trader_desc), do: sort_grouped(tasks, &trader_sort_key/1, :desc)

  defp sort_tasks(tasks, :name_asc), do: sort_grouped(tasks, &name_sort_key/1, :asc)
  defp sort_tasks(tasks, :name_desc), do: sort_grouped(tasks, &name_sort_key/1, :desc)

  defp sort_tasks(tasks, _default) do
    Enum.sort_by(tasks, fn t ->
      {watchlist_sort_key(t), status_sort_key(t.status), String.downcase(t.name)}
    end)
  end

  defp trader_sort_key(t), do: String.downcase(t.trader || "")
  defp name_sort_key(t), do: String.downcase(t.name || "")

  # Shared comparator for the "group by column" sorts (Trader / Status).
  # Watchlisted quests always stay pinned to the top; then rows order by the
  # column's key in the requested direction; ties fall back to status then name
  # (both ascending) so each group stays internally readable and stable.
  defp sort_grouped(tasks, key_fun, dir) do
    Enum.sort(tasks, fn a, b ->
      wa = watchlist_sort_key(a)
      wb = watchlist_sort_key(b)
      ka = key_fun.(a)
      kb = key_fun.(b)

      cond do
        wa != wb ->
          wa < wb

        ka != kb ->
          if dir == :asc, do: ka < kb, else: ka > kb

        true ->
          {status_sort_key(a.status), String.downcase(a.name)} <=
            {status_sort_key(b.status), String.downcase(b.name)}
      end
    end)
  end

  defp watchlist_sort_key(%{watchlisted?: true}), do: 0
  defp watchlist_sort_key(_), do: 1

  # Real-level quests (rank 0) sort ahead of level-less WIP quests (rank 1) in
  # the level orderings, so WIP rows sink to the bottom regardless of direction.
  defp level_present_rank(%{level: l}) when is_integer(l), do: 0
  defp level_present_rank(_), do: 1

  defp level_value(%{level: l}) when is_integer(l), do: l
  defp level_value(_), do: 0

  defp status_sort_key(:available), do: 0
  defp status_sort_key(:locked), do: 1
  defp status_sort_key(:completed), do: 2
  defp status_sort_key(:wip), do: 3

  # Trader filter. A quest carries one or more `{slug, faction}` entries
  # (DB quests have exactly one with faction nil; WIP quests parsed from
  # the wiki `given_by` may have several - "Skier or Peacekeeper", or a
  # faction-conditional "BEAR: Prapor / USEC: Peacekeeper").
  #
  # The quest matches the selected chip if any entry's slug matches and
  # that entry's faction is compatible with the active faction:
  #   * entry.faction == nil          → matches under any faction
  #     (plain single-giver quests and "X or Y" quests)
  #   * entry.faction == "USEC"/"BEAR" → only counts toward that chip
  #     when the user has that faction selected; with no faction
  #     selected the quest shows under *both* givers' chips.
  defp trader_match?(_, nil, _faction), do: true

  defp trader_match?(%{trader_entries: entries}, slug, faction) when is_list(entries) do
    Enum.any?(entries, fn e -> e.slug == slug and entry_faction_ok?(e.faction, faction) end)
  end

  defp trader_match?(_, _, _), do: false

  # A faction-tagged giver entry only counts when no faction is active
  # (show under both) or the active faction matches the entry's.
  defp entry_faction_ok?(nil, _active), do: true
  defp entry_faction_ok?(_entry_faction, active) when active not in [:usec, :bear], do: true
  defp entry_faction_ok?(entry_faction, :usec), do: entry_faction == "USEC"
  defp entry_faction_ok?(entry_faction, :bear), do: entry_faction == "BEAR"

  # Faction-locked tasks are only ever locked to *the other* faction.
  # The API actually uses three values for `factionName`:
  #   - "USEC" / "BEAR" - locked to that faction
  #   - "Any"           - explicitly faction-neutral (487 of 499 tasks
  #                       in the current dump use this; it's the
  #                       common case, not an edge case)
  # `nil` was the value we originally assumed for "neutral" before we
  # had real data. Tarkov.dev hasn't been observed sending `nil` so
  # far, but we treat it as neutral too - it'd only ever appear if
  # the API model changed.
  #
  # Anything else (a hypothetical future faction string we haven't
  # seen) also falls through as visible: it's better to occasionally
  # show an unfamiliar task than to silently hide content because of
  # a whitelist drift, which was the bug that hid 487 tasks before.
  defp faction_match?(%{faction_name: nil}, _), do: true
  defp faction_match?(%{faction_name: "Any"}, _), do: true

  defp faction_match?(%{faction_name: name}, faction) when faction in [:usec, :bear] do
    other_faction =
      case faction do
        :usec -> "BEAR"
        :bear -> "USEC"
      end

    name != other_faction
  end

  defp faction_match?(_, _), do: true

  defp search_match?(_, ""), do: true

  defp search_match?(%{name: name}, needle) do
    String.contains?(String.downcase(name), needle)
  end

  defp filter_match?(_, :all), do: true
  defp filter_match?(%{watchlisted?: true}, :watchlist), do: true
  defp filter_match?(%{status: :available}, :available), do: true
  defp filter_match?(%{status: :locked}, :locked), do: true
  defp filter_match?(%{status: :completed}, :completed), do: true
  # WIP quests live in their own bucket and are excluded from the
  # structured-data filters (kappa/lightkeeper are always false for
  # them, and they never carry :available/:locked/:completed status).
  defp filter_match?(%{status: :wip}, :wip), do: true
  defp filter_match?(%{kappa?: true}, :kappa), do: true
  defp filter_match?(%{lightkeeper?: true}, :lightkeeper), do: true
  defp filter_match?(_, _), do: false

  # ── Status computation ─────────────────────────────────

  # The three states the chip can show. Order matters - `:completed`
  # short-circuits everything else (a completed task is not "locked"
  # even if its level requirement is now above the player's, which
  # can happen if the player rolls back their PMC level).
  # WIP quests have no structured prereqs/level/karma, so they can't be
  # classified Available/Locked/Completed - they get their own status.
  defp compute_status(%{wip?: true}, _pmc_level, _completed, _prereq, _karma, _reqs), do: :wip

  defp compute_status(
         %{id: id, normalized_name: slug} = task,
         pmc_level,
         completed_ids,
         prereq_map,
         scav_karma,
         karma_requirements
       ) do
    cond do
      MapSet.member?(completed_ids, id) -> :completed
      not level_met?(task, pmc_level) -> :locked
      not prereqs_met?(id, completed_ids, prereq_map) -> :locked
      not karma_met?(slug, scav_karma, karma_requirements) -> :locked
      true -> :available
    end
  end

  defp level_met?(%{level: required}, pmc_level)
       when is_integer(required) and is_integer(pmc_level),
       do: pmc_level >= required

  defp level_met?(_, _), do: true

  defp prereqs_met?(task_id, completed_ids, prereq_map) do
    case Map.get(prereq_map, task_id) do
      nil -> true
      prereqs -> MapSet.subset?(prereqs, completed_ids)
    end
  end

  # Scav-karma gate. Most tasks have no karma requirement, so the
  # common path is the catch-all `nil` -> true. The few that do have
  # one (the Compensation-for-Damage chain and the Establish-Contact
  # chain are the well-known examples) get gated against the
  # `:scav_karma` assign. With karma=0 (the current default) every
  # task with a non-trivial karma requirement renders as :locked,
  # which is the in-game truth for a fresh PMC.
  #
  # Indexed by the wiki slug (`normalized_name`), not the task UUID,
  # because the wiki dump is keyed by slug for resilience to a
  # `mix ecto.reset` that re-generates task UUIDs.
  defp karma_met?(slug, scav_karma, karma_requirements) do
    case Map.get(karma_requirements, slug) do
      nil -> true
      {:gte, threshold} -> scav_karma >= threshold
      {:lte, threshold} -> scav_karma <= threshold
    end
  end

  # ── View-model helpers ─────────────────────────────────

  defp to_view_model(task, wiki_slugs) do
    %{
      id: task.id,
      normalized_name: task.normalized_name,
      name: task.name,
      trader: trader_name(task.trader),
      trader_slug: trader_slug(task.trader),
      trader_image: trader_image(task.trader),
      # Single-entry list keeps trader_match?/3 uniform across DB and
      # WIP quests. DB quests are never faction-conditional on the giver.
      trader_entries: db_trader_entries(task.trader),
      level: task.min_player_level || 1,
      kappa?: task.kappa_required,
      lightkeeper?: task.lightkeeper_required,
      faction_name: task.faction_name,
      # DB-backed quest: fully supported, never WIP.
      wip?: false,
      source: :db,
      # Resolved against the slug set `load_task_data/1` already loaded, so this
      # is a MapSet lookup rather than a query. Keyed on the slug rather than
      # `task.id` so a `mix ecto.reset` can't desync the wiki rows from the
      # tasks table.
      has_wiki?: task_has_wiki?(task, wiki_slugs),
      # The quest banner is rendered as a thumbnail on the collapsed
      # row, so it has to be on the row VM (not just the lazily loaded
      # detail payload). It's a plain column on the task record, so this
      # costs nothing extra.
      banner_url: banner_url(task),
      # `:status` is filled in by `filter_tasks/1`.
      # `:expanded?` and `:details` start unset and are populated
      # lazily by `handle_event("toggle_expand", ...)`.
      expanded?: false,
      details: nil
    }
  end

  # ── WIP (wiki-only) view models ────────────────────────

  # Every slug a wiki page might key on for THIS task, used to suppress a
  # duplicate WIP entry. Covers the API `normalized_name`, a slug derived
  # from the API name, AND a slug with any event-zone suffix stripped.
  #
  # During events tarkov.dev temporarily renames quests with a
  # `[PVP ZONE]` / `[PVE ZONE]` tag (e.g. "Easy Money - Part 1 [PVE ZONE]")
  # while the canonical wiki page stays "Easy Money - Part 1". Without the
  # stripped slug the wiki page matches neither the API `normalized_name`
  # ("easy-money-part-1-pve-zone") nor the name slug, so the quest renders
  # twice on the tab - once as the API row and once as a wiki WIP
  # duplicate. Adding the stripped slug lets the WIP merge recognise it as
  # already present. Quests genuinely absent from a mode (e.g. the PVP-only
  # "Decisions, Decisions [PVP ZONE]", which has no PVE counterpart at all)
  # still surface as WIP in the mode that lacks them.
  defp task_dedup_slugs(%{normalized_name: nn, name: name}) do
    Enum.uniq([nn, Slug.normalize_name(name), Slug.normalize_name(strip_event_zone(name))])
  end

  defp task_dedup_slugs(%{normalized_name: nn}), do: [nn]

  # Drop a trailing event-zone tag - " [PVP ZONE]" / " [PVE ZONE]" and any
  # bracketed segment containing the word "zone" (case-insensitive).
  # Names without such a tag pass through unchanged.
  defp strip_event_zone(name) when is_binary(name) do
    Regex.replace(~r/\s*\[[^\]]*\bzone\b[^\]]*\]\s*$/i, name, "") |> String.trim()
  end

  defp strip_event_zone(name), do: name

  # Build a view model for every wiki quest whose slug isn't already
  # backed by a DB task. These render from wiki data alone and are
  # badged WIP. Row identity is the slug (no DB UUID exists), which is
  # safe because slugs and UUIDs never collide in the completion set.
  defp wip_view_models(wiki_quests, db_slugs) do
    wiki_quests
    |> Enum.reject(fn q -> MapSet.member?(db_slugs, q.normalized_name) end)
    |> Enum.map(&wip_view_model/1)
  end

  defp wip_view_model(q) do
    entries = parse_given_by_entries(q.given_by)

    %{
      id: q.normalized_name,
      normalized_name: q.normalized_name,
      name: q.task_name,
      trader: wip_trader_label(entries),
      trader_image: nil,
      # First entry's slug keeps the old single-slug field populated for
      # any caller that still reads it; trader_entries is the real list
      # the filter matches against.
      trader_slug: entries |> List.first(%{}) |> Map.get(:slug),
      trader_entries: entries,
      # Trader chip labels this quest should contribute to the chip list.
      trader_chip_names: Enum.map(entries, & &1.name),
      # Unknown until the API has it - WIP short-circuits status, so
      # these are never gated on.
      level: nil,
      kappa?: false,
      lightkeeper?: false,
      faction_name: nil,
      wip?: true,
      source: :wiki,
      has_wiki?: true,
      # Same row thumbnail every other quest gets. This was hardcoded nil,
      # because the banner lived only inside the wiki manifest's JSONB and
      # `Wiki.all_quests/0` deliberately does not read it — projecting every
      # wiki page at mount just for a thumbnail is the cost that read is shaped
      # to avoid. The consequence was that the two sources disagreed about where
      # a banner belongs: API-backed quests showed one on the collapsed row,
      # wiki-only ones showed an empty placeholder there and their banner inside
      # the expandable panel instead.
      #
      # Promoting the URL to a column on `wiki_quests` makes it one more field on
      # a query that already runs, so both sources now render it in the same place.
      banner_url: q.banner_url,
      expanded?: false,
      details: nil
    }
  end

  # Parse a wiki `given_by` string into a list of giver entries:
  #
  #   %{name: "Skier", slug: "skier", faction: nil}
  #
  # Handles three shapes seen in the dump:
  #
  #   * "Skier"                       → one entry, faction nil
  #   * "Skier or Peacekeeper"        → two entries, faction nil
  #     (either trader can give it - show under both chips)
  #   * "BEAR: PraporUSEC: Peacekeeper" → two entries tagged by faction
  #     (the wiki writes the BEAR/USEC givers run together; the regex
  #     splits on the faction labels). Shows under both chips with no
  #     faction selected, and the matching one when USEC/BEAR is active.
  #
  # Anything unrecognised collapses to a single best-effort entry so we
  # never crash or silently drop a quest from the trader filter.
  defp parse_given_by_entries(given) when is_binary(given) and given != "" do
    cond do
      Regex.match?(~r/\b(BEAR|USEC)\s*:/i, given) ->
        parse_faction_conditional(given)

      String.contains?(given, " or ") ->
        given
        |> String.split(" or ", trim: true)
        |> Enum.flat_map(&to_entry(&1, nil))

      true ->
        to_entry(given, nil)
    end
  end

  defp parse_given_by_entries(_), do: []

  # "BEAR: PraporUSEC: Peacekeeper" (labels run together with no
  # separator) → [{Prapor, BEAR}, {Peacekeeper, USEC}]. We scan for each
  # `FACTION: name` segment, where `name` runs up to the next faction
  # label or end of string.
  defp parse_faction_conditional(given) do
    ~r/(BEAR|USEC)\s*:\s*(.*?)(?=(?:BEAR|USEC)\s*:|$)/i
    |> Regex.scan(given)
    |> Enum.flat_map(fn [_, faction, name] ->
      to_entry(name, String.upcase(faction))
    end)
  end

  # Build a single entry, normalising the name. Returns [] for blanks so
  # callers can flat_map.
  defp to_entry(name, faction) do
    case name |> to_string() |> String.trim() do
      "" ->
        []

      clean ->
        [%{name: display_trader_name(clean), slug: normalize_trader(clean), faction: faction}]
    end
  end

  # Human label for the row's Trader column. Joins multiple givers with
  # " / " so the row reads "Skier / Peacekeeper" rather than the raw
  # wiki string. "-" when there's no giver.
  defp wip_trader_label([]), do: "-"

  defp wip_trader_label(entries),
    do: entries |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(" / ")

  # ── Wiki lookup (tolerant of slug divergence) ──────────
  #
  # A DB task's wiki manifest is normally keyed by the task's
  # `normalized_name` (the dump adopts the DB slug when it can match the
  # quest). But a manifest dumped against an empty/partial DB - or before
  # the Part A matching landed - is keyed by the wiki-derived slug
  # instead, which equals `Slug.normalize_name(task.name)`. tarkov.dev's
  # normalizedName diverges from that slug for ~30 quests (apostrophes
  # deleted, faction/edition suffixes added, "20/20"→"2020"), so a strict
  # `normalized_name` lookup would miss them and the API quest would show
  # no wiki images/guide. Try the DB slug, then the name slug, then the
  # event-zone-stripped name slug - the last is what attaches the wiki
  # page to a Labyrinth `[PVP/PVE ZONE]` task, whose single wiki page is
  # keyed by the suffix-less base slug.
  defp task_wiki(task) do
    task
    |> wiki_lookup_slugs()
    |> Enum.find_value(&Wiki.get_quest/1)
  end

  defp task_has_wiki?(task, wiki_slugs) do
    task
    |> wiki_lookup_slugs()
    |> Enum.any?(&MapSet.member?(wiki_slugs, &1))
  end

  # The ordered, de-duplicated set of slugs a task's wiki content might be
  # keyed under: its API slug, its name slug, and the name slug with any
  # event-zone tag stripped (for the Labyrinth zone quests). Deduped so a
  # plain quest (all three collapse to one slug) issues a single lookup.
  defp wiki_lookup_slugs(task) do
    [
      task.normalized_name,
      Slug.normalize_name(task.name),
      Slug.normalize_name(strip_event_zone(task.name))
    ]
    |> Enum.uniq()
  end

  # ── Expansion helpers ──────────────────────────────────

  # WIP (wiki-only) quest: no DB row, so the detail payload is built
  # entirely from the wiki manifest - banner, plain objectives text,
  # and the guide. A `wip?: true` marker drives the template branch and
  # the "not fully supported yet" notice. Cache key is the slug (the
  # row id), matching the `Map.fetch(cache, task_id)` lookup above.
  #
  # API-backed quests render their banner as a row thumbnail instead (see
  # `to_view_model/1`), so this is the only detail panel that still shows
  # one - the manifest that carries it isn't read until expansion.
  defp load_details(%{wip?: true, normalized_name: slug}, cache) do
    wiki = Wiki.get_quest(slug)

    details = %{
      wip?: true,
      wiki: wiki,
      banner_url: wip_banner_url(wiki),
      objectives_text: (wiki && wiki.objectives_text) || []
    }

    {details, Map.put(cache, slug, details)}
  end

  defp load_details(%{id: task_id}, cache) do
    task = Tasks.get_task_details(task_id)
    # Wiki is keyed by the slug, not the UUID, so a `mix ecto.reset`
    # (which assigns fresh UUIDs to every task) doesn't desync the
    # lookup from the on-disk dump. `task` is the freshly-loaded
    # struct from the DB, so `task.normalized_name` is current.
    wiki = task && task_wiki(task)

    details = %{
      wip?: false,
      task: task,
      wiki: wiki,
      objectives: objectives_view_model(task, wiki),
      requirements: requirements_view_model(task, wiki),
      rewards: rewards_view_model(task),
      required_items: Tasks.required_items_for(task)
    }

    {details, Map.put(cache, task_id, details)}
  end

  defp wip_banner_url(%{banner: %{url: url}}) when is_binary(url), do: url
  defp wip_banner_url(_), do: nil

  # Rebuild a row's stream entry with the expansion flag and (when
  # expanded) the cached details payload. The base VM is sourced from
  # `:filtered_tasks` (not `:all_tasks`) because the per-row `:status`
  # field is added by `filter_tasks/1` - `to_view_model/1` doesn't
  # know about completion / level / prereqs. Without this the
  # rebuilt stream entry was missing `:status` and the template
  # crashed with `KeyError: key :status not found` on every expand.
  defp row_with_expansion(task_id, filtered_tasks, cache, expanded_ids, details \\ nil) do
    case Enum.find(filtered_tasks, fn t -> t.id == task_id end) do
      nil ->
        # The task isn't in the current filtered list - should never
        # happen for a click on a visible row, but treat as no-op
        # (returns a minimal collapsed VM that satisfies the template
        # contract).
        %{
          id: task_id,
          expanded?: false,
          details: nil,
          status: :available,
          wip?: false,
          watchlisted?: false
        }

      task ->
        Map.merge(task, %{
          expanded?: MapSet.member?(expanded_ids, task_id),
          details: details || Map.get(cache, task_id)
        })
    end
  end

  # Build an ordered list of `{api_objective, wiki_images}` pairs
  # for the detail panel. The wiki side is keyed by 1-based index
  # because that's how the parser anchors images to bullets; if the
  # wiki has more (or fewer) objectives than the API, anything past
  # the API list just isn't rendered. In practice they line up.
  defp objectives_view_model(task, wiki) do
    objs = api_objectives(task)
    wiki_imgs_by_idx = (wiki && wiki.objective_images) || %{}

    objs
    |> Enum.with_index(1)
    |> Enum.map(fn {obj, idx} ->
      %{
        index: idx,
        description: api_objective_description(obj),
        type: api_objective_type(obj),
        wiki_images: Map.get(wiki_imgs_by_idx, idx, [])
      }
    end)
  end

  # The API exposes a `:objectives` association on `Task` which is a
  # list of polymorphic objective rows (Item, Skill, Mark, Extract,
  # ...). We sort by the `:position` column the sync now writes (set
  # from the API response order); `nil` positions sink to the bottom
  # and are tie-broken by inserted_at + id so unmigrated rows still
  # render in a stable order. After re-running Tasks.Sync.run/0 every
  # row has a real position.
  defp api_objectives(%{objectives: objs}) when is_list(objs) do
    Enum.sort_by(objs, fn o ->
      {is_nil(o.position), o.position || 0, o.inserted_at, o.id}
    end)
  end

  defp api_objectives(_), do: []

  defp api_objective_description(%{description: d}) when is_binary(d) and d != "", do: d
  defp api_objective_description(_), do: "(no description)"

  defp api_objective_type(%{type: t}) when is_binary(t), do: t
  defp api_objective_type(_), do: nil

  # Bundle the various reward associations into the shape the right
  # column expects. We split each reward list by `reward_phase`
  # (`:start` = on-accept, `:finish` = on-turn-in) so the template
  # can render two clearly-labeled blocks instead of intermingling
  # them. Returning empty lists (rather than nil) for absent phases
  # lets the template render unconditionally without nil-guards.
  defp rewards_view_model(task) do
    %{
      experience: Map.get(task, :experience),
      items: split_by_phase(list_or_empty(task, :item_rewards)),
      trader_standing: split_by_phase(list_or_empty(task, :trader_standing_rewards)),
      skills: split_by_phase(list_or_empty(task, :skill_rewards)),
      trader_unlocks: split_by_phase(list_or_empty(task, :trader_unlocks)),
      offer_unlocks: split_by_phase(list_or_empty(task, :offer_unlocks))
    }
  end

  defp split_by_phase(list) do
    grouped = Enum.group_by(list, & &1.reward_phase)
    %{start: Map.get(grouped, :start, []), finish: Map.get(grouped, :finish, [])}
  end

  defp list_or_empty(task, key) do
    case Map.get(task, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp banner_url(task), do: Map.get(task, :task_image_link)

  # Build the right-column "Requirements" view model. Skips fields
  # that don't carry useful information for the player:
  #
  #   - level  - only shown if > 1 (every quest is "level >= 1" by
  #              definition; saying it adds noise)
  #   - faction - only shown if it's USEC- or BEAR-locked. "Any" and
  #               nil mean both factions can take the quest.
  #   - task / trader prerequisites - only shown when present; the
  #     UI returns empty lists for tasks with no prereqs (the common
  #     case, especially for trader-LL1 introductory quests).
  #
  # Returns `%{lines: [%{statuses:, text:}], any?: boolean}`. The five
  # categories are flattened into one ordered list here rather than
  # branched over in the template, so the block has a single list to
  # render. The order is the one that reads best - hard gates first
  # (level, faction, karma), then the quests and traders you have to work
  # through. `:any?` is precomputed so the template can self-hide the
  # whole block when there's nothing meaningful to show.
  #
  # `:statuses` carries a prerequisite's status list ("complete",
  # "active", "failed") through to the template, which colours it a word
  # at a time. It stays structured rather than being baked into the
  # sentence because it's what the reader scans for: on a list of six
  # prerequisites, "which of these do I have to finish" should be
  # answerable without reading any of the quest names.
  #
  # Faction and trader lines share the same "Prefix: value" shape but are
  # plain text. The colours here are states - `go` for something to
  # finish, `rust` for something to break - and a faction or a trader's
  # name isn't a state.
  defp requirements_view_model(task, wiki) do
    min_level = if (task.min_player_level || 1) > 1, do: task.min_player_level, else: nil

    faction =
      case task.faction_name do
        f when f in [nil, "", "Any"] -> nil
        f -> f
      end

    task_reqs =
      task
      |> list_or_empty(:task_requirements)
      |> Enum.map(fn req ->
        %{
          name: prerequisite_task_name(req),
          statuses: req.status || []
        }
      end)
      |> Enum.reject(fn %{name: n} -> is_nil(n) end)

    karma = wiki && wiki[:karma_requirement]

    trader_reqs =
      task
      |> list_or_empty(:trader_requirements)
      |> Enum.reject(&duplicate_karma_requirement?(&1, karma))
      |> Enum.map(fn req ->
        %{
          trader: trader_name_of(req.trader),
          requirement_type: req.requirement_type,
          compare: req.compare_method,
          value: req.value
        }
      end)

    lines =
      [
        min_level && req_line("Must be level #{min_level} to start this quest"),
        faction && req_line("Faction: #{faction} only"),
        karma && req_line(karma_phrase(karma))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(Enum.map(task_reqs, &prereq_line/1))
      |> Enum.concat(Enum.map(trader_reqs, &trader_req_line/1))

    %{lines: lines, any?: lines != []}
  end

  defp req_line(text), do: %{statuses: [], text: text}
  defp req_line(statuses, text), do: %{statuses: statuses, text: text}

  # Fence's "reputation" IS scav karma. The API models the gate as a Fence
  # reputation comparison; the wiki states the same gate in the words a
  # player actually uses ("Scav karma of -1 or lower"), and this block
  # already renders that from `karma`. Eight quests carried both - the five
  # Compensation for Damage parts, Is This a Reference?, Network Provider -
  # Part 1 and Establish Contact - saying the same thing twice, once in API
  # terms.
  #
  # Dropped only when the karma line is actually present. That value is
  # parsed out of a wiki page, so a quest whose page hasn't been scraped
  # has none, and dropping unconditionally would delete the requirement
  # rather than deduplicate it.
  defp duplicate_karma_requirement?(%{trader: %{normalized_name: "fence"}}, karma),
    do: karma != nil

  defp duplicate_karma_requirement?(_req, _karma), do: false

  defp prerequisite_task_name(%{prerequisite_task: %{name: name}}) when is_binary(name), do: name
  defp prerequisite_task_name(_), do: nil

  defp trader_name(%{name: name}) when is_binary(name), do: display_trader_name(name)
  defp trader_name(_), do: "-"

  # Defensive normalization for trader names that show up as
  # all-lowercase in the DB (e.g. "ref", "jaeger" - these were seeded
  # by the Hideout sync before our Tasks sync ran, and Hideout uses
  # the lowercase normalizedName as the display name). The Tasks sync
  # *does* upsert the proper-cased name from tarkov.dev's
  # `trader.name`, so a re-sync corrects the data - but we belt-and-
  # suspenders the rendering here in case the order of syncs ever
  # leaves things ugly again. We only touch all-lowercase strings, so
  # already-mixed-case names like "BTR Driver" are left untouched.
  defp display_trader_name(""), do: ""

  defp display_trader_name(name) do
    if name == String.downcase(name) do
      String.capitalize(name)
    else
      name
    end
  end

  defp trader_slug(%{normalized_name: slug}) when is_binary(slug), do: slug
  defp trader_slug(_), do: nil

  # Single-entry trader list for a DB quest (faction nil - the API
  # doesn't express faction-conditional givers).
  defp db_trader_entries(%{name: name, normalized_name: slug})
       when is_binary(name) and is_binary(slug),
       do: [%{name: display_trader_name(name), slug: slug, faction: nil}]

  defp db_trader_entries(_), do: []

  # ── Trader chip list ───────────────────────────────────

  # Built from the DB so the list never shows traders with zero
  # tasks and picks up any new trader the API starts returning, then
  # unioned with the quest-givers of any WIP quests so the trader
  # filter covers wiki-only quests too. The `"All"` chip is hardcoded
  # as the leading entry. Names are normalized via
  # `display_trader_name/1` so DB drift (e.g. all-lowercase "ref")
  # doesn't leak into the chip labels.
  defp build_trader_chip_list(wip_vms) do
    db_traders =
      Tasks.traders_with_tasks()
      |> Enum.map(&display_trader_name(&1.name))

    wip_traders =
      wip_vms
      |> Enum.flat_map(fn vm -> Map.get(vm, :trader_chip_names, []) end)
      |> Enum.reject(&(&1 in [nil, "", "-"]))

    ["All" | (db_traders ++ wip_traders) |> Enum.uniq() |> Enum.sort()]
  end

  defp normalize_trader(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # ── Filter parsing ─────────────────────────────────────

  defp parse_filter(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @valid_filters, do: atom, else: :all
  rescue
    ArgumentError -> :all
  end

  defp parse_filter(_), do: :all

  # ── Function components for the detail panel ──────────

  @doc """
  Required-items block. Renders every item referenced by any
  objective's payload - find / handover items, marker items,
  use-any items, required keys, AND quest-exclusive items
  (Golden Zibbo lighter, Cult medallion, etc.). Quest items
  live in the same `items` table as regular items so they
  render exactly like any other required item from the
  player's perspective.

  Each row carries the item's icon in a tier-colored square
  (consistent with the reward / craft tiles elsewhere), its name as a
  click-through link to `/items?q=<name>` (new tab), and an `×N`
  count when more than one is required.

  There is deliberately no "FiR" badge. The found-in-raid condition
  is already stated - and highlighted in red by `fir_text/1` - in the
  objective sentence right below this block, so a pill here repeated
  it on every affected row and made the list harder to scan for what
  it is actually for: which items to go and get.

  `@items` is the list of `%{item:, found_in_raid:, count:}` maps
  produced by `Tasks.required_items_for/1`; the found-in-raid flag
  comes along for the ride but isn't rendered.

  ## Fitting the panel

  Every item is rendered, in one flat list, in alphabetical order.
  How much of it is *visible* is decided client-side by the `FitList`
  hook, which caps this block at the height of the block named by
  `@fit_to` (the requirements + rewards column) and scrolls the
  overflow, so the two columns of the panel end on the same line. The
  hook also picks the column count - one while the list fits, two
  once it doesn't.

  That split of responsibilities is deliberate. Both inputs are
  pixel measurements of rendered text and images: the neighbouring
  column's height, and one row's height. The server knows neither,
  and a server-side estimate would have to guess at font metrics and
  wrapping, then guess again on every window resize.

  The list is a `grid`, not CSS multi-columns, because it fills
  row-major: the next item goes to the RIGHT, then wraps to the next
  row, so an alphabetical list reads A B / C D across the two
  columns. The row gap lives on each `li` as a margin (rather than
  `gap-y`) because that's the value the hook measures to round its
  cap down to whole rows.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true

  attr :fit_to, :string,
    required: true,
    doc: "CSS selector of the block whose height this list should match"

  def required_items_block(assigns) do
    ~H"""
    <%= if @items != [] do %>
      <section id={@id} data-fit-section class="space-y-3">
        <.eyebrow>Required items</.eyebrow>
        <%!-- `pr-1` keeps the scrollbar off the item names; the page-wide
             scrollbar styling in app.css already themes it to the HUD. --%>
        <div
          id={@id <> "-scroll"}
          phx-hook="FitList"
          data-fit-to={@fit_to}
          class="overflow-y-auto overscroll-contain pr-1"
        >
          <ul data-fit-list class="grid grid-cols-1 gap-x-6">
            <li :for={entry <- @items} class="flex items-center gap-2 min-w-0 mb-2 last:mb-0">
              <.link
                navigate={"/items?q=" <> URI.encode(entry.item.name)}
                class="group flex items-center gap-2 min-w-0"
                title={entry.item.name}
              >
                <.item_tile item={entry.item} size="w-8 h-8" link={false} />
                <span class="text-sm text-amber group-hover:underline truncate">
                  {entry.item.name}
                </span>
              </.link>
              <span :if={entry.count && entry.count > 1} class="text-xs text-fog-500 shrink-0">
                ×{entry.count}
              </span>
            </li>
          </ul>
        </div>
      </section>
    <% end %>
    """
  end

  @doc """
  Wiki-style item tile for the rewards block.

  Mirrors the `craft_item_tile` used on the Items page: the item's
  icon sits in a tier-colored square with an `×N` quantity badge in
  the corner, and the whole tile links to `/items?q=<name>` in a
  new tab. Using icons (instead of a "N × name" text line) makes a
  quest's rewards scannable at a glance and keeps the Tasks and
  Items pages visually consistent.
  """
  attr :item, :any, required: true
  attr :quantity, :any, default: nil

  def reward_item_tile(assigns) do
    ~H"""
    <.item_tile item={@item} qty={@quantity} size="w-[64px] h-[64px]" />
    """
  end

  @doc """
  Right-column requirements block. Surfaces the task's level / faction
  / prerequisite task / trader-loyalty gates as a flat sentence list.
  Self-hides when none of the four categories applies (i.e. the
  introductory quests every player can take immediately).

  Mirrors the visual treatment of `<.reward_block />` so the right
  column reads consistently as the player scans down it.

  Every line renders: this block is never capped, folded or scrolled.
  One quest in the game makes that look expensive - Collector gates on
  70 others - and a 71-line block is a tall block. It's also the
  truthful rendering of a quest whose entire nature is "finish
  everything else first", and the reader who opened Collector is
  precisely the reader who wants that list. The rest of the panel is
  insulated from it instead: `FitList` clamps the required-items list
  to its own ceiling, so a tall right column can't drag the left one
  with it.

  `@requirements` is the `%{lines: [%{statuses:, text:}], any?:}` map
  from `requirements_view_model/2` - already flattened, in display order.

  A line's `:statuses` are its prerequisite statuses, rendered as a
  coloured prefix ahead of the quest name ("Complete: Shortage") by
  `status_prefix/1`. Everything else is plain text, including the
  faction and trader lines that happen to share the same "Prefix: value"
  shape - see `requirements_view_model/2`.
  """
  attr :id, :string, required: true
  attr :requirements, :map, required: true

  def requirements_block(assigns) do
    ~H"""
    <%= if @requirements.any? do %>
      <section id={@id} class="hud-inset p-4 space-y-3">
        <.eyebrow>Requirements</.eyebrow>
        <ul class="space-y-1.5 text-sm text-fog-200">
          <li :for={req <- @requirements.lines}>{status_prefix(req.statuses)}{req.text}</li>
        </ul>
      </section>
    <% end %>
    """
  end

  # The coloured "Complete:" / "Active / Failed:" prefix on a prerequisite
  # line, as HEEx-renderable iodata.
  #
  # Colour is per WORD, not per line. "Complete" and "Active" are things to
  # go and do; "Failed" is a thing to break, and it can't be undone - so a
  # mixed "Complete / Failed" has to show both polarities instead of
  # picking one for the pair. The prefix is what the reader scans for on a
  # long prerequisite list, which is why it leads the line and carries the
  # only colour in it.
  #
  # Built as iodata rather than nested tags in the template, following
  # `fir_text/1`: the separator and the colon are then part of the value
  # instead of whitespace between elements, so neither HEEx's whitespace
  # collapsing nor a later run of the formatter can move them. As there,
  # only the fixed span markup is ever marked safe - the API's own status
  # strings stay escaped.
  @span_close Phoenix.HTML.raw("</span>")
  @status_separator Phoenix.HTML.raw(~s(<span class="text-fog-600"> / </span>))
  @status_go Phoenix.HTML.raw(~s(<span class="text-go">))
  @status_rust Phoenix.HTML.raw(~s(<span class="text-rust">))

  defp status_prefix([]), do: []

  defp status_prefix(statuses) do
    words =
      statuses
      |> Enum.map(&[status_open(&1), String.capitalize(&1), @span_close])
      |> Enum.intersperse(@status_separator)

    [words, ": "]
  end

  defp status_open("failed"), do: @status_rust
  defp status_open(_), do: @status_go

  defp karma_phrase({:gte, n}) when n > 0, do: "Scav karma of at least +#{n}"
  defp karma_phrase({:gte, n}) when n == 0, do: "Scav karma of at least 0"
  defp karma_phrase({:gte, n}), do: "Scav karma of at least #{n}"
  defp karma_phrase({:lte, n}) when n < 0, do: "Scav karma of #{n} or lower"
  defp karma_phrase({:lte, n}), do: "Scav karma of #{n} or lower"

  # A prerequisite quest, as its status list plus the quest name. The
  # statuses stay a list all the way to the template, which colours them a
  # word at a time - see `status_prefix/1`.
  #
  # An empty status list means the API named a prerequisite without saying
  # what has to be true of it. That doesn't happen in the current data, so
  # rather than invent a colour for it the line reads "Requires: <name>" as
  # plain text.
  defp prereq_line(%{name: name, statuses: []}), do: req_line("Requires: #{name}")

  defp prereq_line(%{name: name, statuses: statuses}),
    do: req_line(canonical_statuses(statuses), name)

  # Display order for a multi-status prerequisite.
  #
  # The API's array order isn't stable: 20 prerequisites arrive as
  # ["active", "complete"] and 3 as ["complete", "active"] - the same
  # requirement, rendered two different ways. Sorting to a fixed order
  # means one meaning has one appearance. Unknown statuses (none today)
  # sort to the end rather than being dropped, so a new API vocabulary
  # word still shows up.
  @status_order ["complete", "active", "failed"]

  defp canonical_statuses(statuses) do
    statuses
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn status ->
      Enum.find_index(@status_order, fn known -> known == status end) || length(@status_order)
    end)
  end

  # Render a TraderRequirement as a sentence from its
  # `requirement_type compare value` triple.
  #
  # The API's vocabulary here is "level" (trader loyalty) and "reputation".
  # It is NOT "loyaltyLevel" / "playerLevel" - those were the old GraphQL
  # names, and since the move to the JSON API (which `Tasks.Sync` stores
  # verbatim) the clauses matching them were dead code. Every trader
  # requirement had been falling through to the raw fallback and printing
  # API jargon: "Prapor: level >= 2", "Lightkeeper: reputation <= 0".
  defp trader_req_line(%{trader: trader, requirement_type: type, compare: cmp, value: v}),
    do: req_line("#{trader}: #{requirement_type_label(type)} #{compare_symbol(cmp)} #{v}")

  defp requirement_type_label("level"), do: "loyalty level"
  defp requirement_type_label("reputation"), do: "reputation"
  # An unrecognised type renders as itself: better a slightly technical
  # word than a silently missing requirement.
  defp requirement_type_label(type) when is_binary(type) and type != "", do: type
  defp requirement_type_label(_), do: "requirement"

  defp compare_symbol(">="), do: "≥"
  defp compare_symbol("<="), do: "≤"
  defp compare_symbol(cmp) when is_binary(cmp) and cmp != "", do: cmp
  defp compare_symbol(_), do: "="

  @doc """
  Right-column rewards block. Renders one phase's worth of rewards
  (`:start` for on-accept items, `:finish` for everything else)
  including XP, items, trader standing, skills, trader unlocks, and
  offer unlocks. Self-hides when there's nothing for this phase.

  We render the experience number only on the `:finish` phase since
  the API exposes a single `task.experience` for the on-turn-in
  reward - there's no "XP on accept" concept.
  """
  attr :title, :string, required: true
  attr :rewards, :map, required: true
  attr :phase, :atom, required: true, values: [:start, :finish]
  attr :experience, :any, default: nil

  def reward_block(assigns) do
    items = get_in(assigns.rewards.items, [assigns.phase]) || []
    standing = get_in(assigns.rewards.trader_standing, [assigns.phase]) || []
    skills = get_in(assigns.rewards.skills, [assigns.phase]) || []
    trader_unlocks = get_in(assigns.rewards.trader_unlocks, [assigns.phase]) || []
    offer_unlocks = get_in(assigns.rewards.offer_unlocks, [assigns.phase]) || []

    show_xp? =
      assigns.phase == :finish and
        is_integer(assigns.experience) and assigns.experience > 0

    empty? =
      items == [] and standing == [] and skills == [] and
        trader_unlocks == [] and offer_unlocks == [] and not show_xp?

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:standing, standing)
      |> assign(:skills, skills)
      |> assign(:trader_unlocks, trader_unlocks)
      |> assign(:offer_unlocks, offer_unlocks)
      |> assign(:show_xp?, show_xp?)
      |> assign(:empty?, empty?)

    ~H"""
    <%= unless @empty? do %>
      <section class="hud-inset p-4 space-y-3">
        <.eyebrow>{@title}</.eyebrow>

        <%= if @items != [] do %>
          <div class="flex flex-wrap gap-2">
            <.reward_item_tile :for={r <- @items} item={r.item} quantity={r.quantity} />
          </div>
        <% end %>

        <%= if @standing != [] do %>
          <ul class="space-y-1.5">
            <li :for={r <- @standing} class={"text-sm " <> standing_class(r.standing)}>
              {trader_name_of(r.trader)} {format_standing(r.standing)}
            </li>
          </ul>
        <% end %>

        <%!-- XP sits under the standing lines, not above the item tiles: the
             block then reads tiles-then-text instead of text-tiles-text, and XP
             lands next to the other one-line numeric reward it most resembles.
             Same size and weight as a standing line, in the `warn` yellow the
             WIP badge uses - clear of the amber that means "link" or "item"
             elsewhere on the panel, and of the go/rust pair that carries
             standing polarity. --%>
        <%= if @show_xp? do %>
          <div class="text-sm text-warn">+{@experience} XP</div>
        <% end %>

        <%= if @skills != [] do %>
          <ul class="space-y-1.5">
            <li :for={r <- @skills} class="text-sm text-fog-200">
              {format_standing(r.level)} {skill_name(r.skill)}
            </li>
          </ul>
        <% end %>

        <%= if @trader_unlocks != [] do %>
          <ul class="space-y-1.5">
            <li :for={r <- @trader_unlocks} class="text-sm text-fog-200">
              Unlocks {trader_name_of(r.trader)} as a vendor
            </li>
          </ul>
        <% end %>

        <%= if @offer_unlocks != [] do %>
          <ul class="space-y-1.5">
            <li :for={r <- @offer_unlocks} class="flex items-center gap-2 text-sm text-fog-200">
              <.item_tile :if={r.item} item={r.item} size="w-8 h-8" />
              <span>Unlocks {item_name(r.item)} at {trader_name_of(r.trader)} LL{r.level}</span>
            </li>
          </ul>
        <% end %>
      </section>
    <% end %>
    """
  end

  # ── Reward formatting helpers ──────────────────────────

  defp item_name(%{name: name}) when is_binary(name), do: name
  defp item_name(_), do: "(unknown item)"

  defp skill_name(%{name: name}) when is_binary(name), do: name
  defp skill_name(_), do: "(unknown skill)"

  # The trader on a reward row is preloaded; for unloaded / nil cases
  # we still render *something* rather than crashing.
  defp trader_name_of(%{name: name}) when is_binary(name), do: display_trader_name(name)
  defp trader_name_of(_), do: "-"

  # Trader standing is fractional and signed (e.g. +0.04 Skier rep,
  # -0.05 Therapist for some questlines). Format with the leading
  # sign so the polarity is unmistakable in the UI.
  defp format_standing(value) when is_number(value) do
    cond do
      value > 0 -> "+" <> :erlang.float_to_binary(value * 1.0, decimals: 2)
      value < 0 -> :erlang.float_to_binary(value * 1.0, decimals: 2)
      true -> "0.00"
    end
  end

  defp format_standing(_), do: ""

  defp standing_class(value) when is_number(value) and value > 0, do: "text-go"
  defp standing_class(value) when is_number(value) and value < 0, do: "text-rust"
  defp standing_class(_), do: "text-fog-200"

  # ── Template helpers ───────────────────────────────────

  @doc """
  Renders a wiki "Guide" block list (headings, prose, zoomable galleries).
  Shared by the WIP and API-backed detail panels.
  """
  attr :blocks, :list, required: true
  attr :dom_prefix, :string, required: true

  def guide_blocks(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= for {block, idx} <- Enum.with_index(@blocks) do %>
        <p :if={block.kind == :heading} class={guide_heading_class(block.level)}>{block.text}</p>
        <p :if={block.kind == :prose} class="text-sm text-fog-300 leading-relaxed wrap-break-word">
          {block.text}
        </p>
        <div :if={block.kind == :gallery} class="flex flex-wrap gap-3">
          <.zoomable_image
            :for={{img, i} <- Enum.with_index(block.images)}
            id={"#{@dom_prefix}-#{idx}-#{i}"}
            src={img.file["url"] || ""}
            alt={img.caption || ""}
            caption={img.caption}
            width={img.file["width"]}
            height={img.file["height"]}
          />
        </div>
      <% end %>
    </div>
    """
  end

  @doc false
  def status_label(:available), do: "Available"
  def status_label(:locked), do: "Locked"
  def status_label(:completed), do: "Completed"
  def status_label(:wip), do: "WIP"

  @doc false
  def status_classes(:available), do: "bg-go/10 text-go border-go/40"
  def status_classes(:locked), do: "bg-ink-900 text-fog-500 border-line-strong"
  def status_classes(:completed), do: "bg-amber/10 text-amber border-amber/30"
  def status_classes(:wip), do: "bg-warn/10 text-warn border-warn/30"

  # Trader portrait thumbnails come straight from the synced trader
  # record (`image_link`, populated from tarkov.dev's `imageLink`).
  # Returns nil when the trader is unknown / not yet synced, in which
  # case the row renders the name with no thumbnail.
  defp trader_image(%{image_link: link}), do: link
  defp trader_image(_), do: nil

  @doc """
  Colours a task's required level against the operator's PMC level: green when
  the level is met, red when it isn't, neutral when the task has no level gate.
  """
  def level_class(nil, _pmc_level), do: "text-fog-500"

  def level_class(level, pmc_level) when is_integer(pmc_level) and pmc_level >= level,
    do: "text-go"

  def level_class(_level, _pmc_level), do: "text-rust"
end
