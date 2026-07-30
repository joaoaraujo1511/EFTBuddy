defmodule EftBuddyWeb.EventsLive.Index do
  use EftBuddyWeb, :live_view

  alias EftBuddy.Events
  alias EftBuddy.Progress
  alias EftBuddyWeb.ClientBridge

  @valid_views ~w(all active watchlist)a

  # Key (inside the ACTIVE GAME MODE's slice of the progress blob) the event
  # watchlist is stored under. Read from `@client_state` in `mount/3`, written on
  # every toggle via `ClientBridge.put_progress/2`. Stored as a flat list of
  # stable event `normalized_name` slugs so the watchlist survives a reseed.
  # PVP and PVE keep separate lists (see `EftBuddy.Progress`).
  @watchlist_key "events_watchlist"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Events")
      |> assign(
        :page_description,
        "Current and upcoming limited-time Escape from Tarkov events and the quests tied to them."
      )
      |> assign(:active, :events)
      |> assign(:query, "")
      |> assign(:view, :all)
      |> assign(:counts, %{all: 0, active: 0, watchlist: 0})
      # The operator's event watchlist - stable event slugs read from
      # `@client_state`, the server-authoritative progress blob assigned by the
      # `EftBuddyWeb.OperatorState` hook before the first render. Only a cold
      # connect hydrates later, via `{:client_state_restored, ...}`.
      |> then(&assign(&1, :watchlist_slugs, read_watchlist_slugs(&1)))
      # Per-quest expansion state, mirroring the Tasks tab: each expanded
      # quest's projected walkthrough is lazy-loaded on first open and
      # cached for the lifetime of the LiveView, so the index itself only
      # reads the cheap event/quest-summary rows (never the heavy
      # per-quest manifests) on mount.
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:details_cache, %{})
      |> assign(:events, [])
      |> load_events()

    {:ok, socket}
  end

  # Load the full event list only on the connected mount so the work isn't
  # repeated on the disconnected (static) render. `handle_params/3` then
  # derives the visible (filtered + sorted) list from it.
  defp load_events(socket) do
    if connected?(socket) do
      assign(socket, :all_events, Events.list_events())
    else
      assign(socket, :all_events, [])
    end
  end

  # Read `?q=` (search) and `?view=` (all|active) from the URL into
  # assigns, then derive the visible list: search filters by event name OR
  # any associated quest name; the view tab narrows to active; and the
  # result is sorted active-events-first (each group already newest-first
  # from the context). Driving this through the URL keeps the active
  # filter + search shareable / bookmarkable / refresh-safe, like the
  # other tabs.
  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.slice(0, 100)
    view = parse_view(params["view"])

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:view, view)
     |> refresh_events()}
  end

  # Derive the visible (search-filtered, view-narrowed, sorted) event list
  # plus the per-view counts from the current assigns. Each event is tagged
  # with `:watchlisted?` so the template can paint its star and the sort can
  # float watchlisted events to the top. Shared by `handle_params/3` (filter /
  # search changes), the watchlist toggle, and the client-state restore.
  defp refresh_events(socket) do
    %{all_events: all_events, query: query, view: view, watchlist_slugs: watchlist} =
      socket.assigns

    needle = query |> String.trim() |> String.downcase()

    search_filtered =
      all_events
      |> Enum.filter(&search_match?(&1, needle))
      |> Enum.map(&Map.put(&1, :watchlisted?, MapSet.member?(watchlist, &1.slug)))

    counts = %{
      all: length(search_filtered),
      active: Enum.count(search_filtered, &(&1.status == "active")),
      watchlist: Enum.count(search_filtered, & &1.watchlisted?)
    }

    events =
      search_filtered
      |> Enum.filter(&view_match?(&1, view))
      |> sort_events()

    socket
    |> assign(:counts, counts)
    |> assign(:events, events)
  end

  # Debounced search: patch the URL so refresh / sharing preserves the
  # query; `handle_params/3` reflows the list. `replace: true` keeps the
  # browser history clean across keystrokes.
  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: events_path(query, socket.assigns.view), replace: true)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: events_path("", socket.assigns.view), replace: true)}
  end

  # Add/remove an event from the operator's watchlist. The star is flipped
  # instantly client-side (paired `JS.toggle_class`); here we update the
  # canonical slug set, persist it to localStorage via the `Hud` hook, and
  # reflow so a watchlisted event sorts to the top (see `sort_events/1`).
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
     |> refresh_events()}
  end

  def handle_event("toggle_watchlist", _params, socket), do: {:noreply, socket}

  # Toggle one quest's walkthrough. Lazy-loads + caches the projected
  # detail the first time a quest opens (nil is a valid, cached result -
  # the quest's page failed to scrape or hasn't been scraped yet).
  def handle_event("toggle_quest", %{"id" => quest_id}, socket) do
    %{expanded_ids: expanded, details_cache: cache} = socket.assigns

    if MapSet.member?(expanded, quest_id) do
      {:noreply, assign(socket, :expanded_ids, MapSet.delete(expanded, quest_id))}
    else
      cache =
        if Map.has_key?(cache, quest_id),
          do: cache,
          else: Map.put(cache, quest_id, Events.get_quest_detail(quest_id))

      {:noreply,
       socket
       |> assign(:expanded_ids, MapSet.put(expanded, quest_id))
       |> assign(:details_cache, cache)}
    end
  end

  # The progress blob changed: either a cold connect handing up localStorage for
  # the first time, or another of the operator's tabs editing the watchlist. On a
  # live navigation the blob is already present in `mount/3`, so this no longer
  # fires there.
  @impl true
  def handle_info({:client_state_restored, state}, socket) when is_map(state) do
    socket = assign(socket, :client_state, state)

    {:noreply,
     socket
     |> assign(:watchlist_slugs, read_watchlist_slugs(socket))
     |> refresh_events()}
  end

  # The event list itself is the same in both modes, but the watchlist is not -
  # it's stored per game mode, so a PVP/PVE flip swaps which events are marked
  # (and therefore which float to the top).
  def handle_info({:sidebar_state_changed, :mode, _value}, socket) do
    {:noreply,
     socket
     |> assign(:watchlist_slugs, read_watchlist_slugs(socket))
     |> refresh_events()}
  end

  # The remaining operator/HUD pings (faction/level/karma) don't change the event
  # list, so they fall through here as a no-op.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Persist the event watchlist: into the operator's authoritative session AND
  # through to localStorage.
  defp persist_watchlist(socket) do
    ClientBridge.put_progress(socket, %{
      @watchlist_key => MapSet.to_list(socket.assigns.watchlist_slugs)
    })
  end

  # Pull the active game mode's persisted watchlist out of the progress blob,
  # defensively: a missing / malformed entry yields an empty set.
  defp read_watchlist_slugs(%{assigns: %{client_state: state, mode: mode}}) do
    case Progress.get(state, mode, @watchlist_key) do
      list when is_list(list) ->
        list |> Enum.filter(&(is_binary(&1) and &1 != "")) |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # ── Filter / sort / URL helpers ─────────────────────────

  @doc """
  Build an `/events` path with the search query + view tab preserved as
  query params, so changing one filter never drops the other. Default
  values (`""` query, `:all` view) are omitted to keep the bare URL clean.
  """
  def events_path(query, view) do
    params =
      []
      |> maybe_put(:q, query_param(query))
      |> maybe_put(:view, view_param(view))

    case params do
      [] -> "/events"
      _ -> "/events?" <> URI.encode_query(params)
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, value}]

  defp query_param(q) when q in ["", nil], do: nil
  defp query_param(q), do: q

  defp view_param(:all), do: nil
  defp view_param(view) when is_atom(view), do: Atom.to_string(view)

  defp parse_view(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @valid_views, do: atom, else: :all
  rescue
    ArgumentError -> :all
  end

  defp parse_view(_), do: :all

  defp view_match?(_event, :all), do: true
  defp view_match?(%{status: "active"}, :active), do: true
  defp view_match?(%{watchlisted?: true}, :watchlist), do: true
  defp view_match?(_event, _view), do: false

  defp search_match?(_event, ""), do: true

  defp search_match?(event, needle) do
    String.contains?(String.downcase(event.name), needle) or
      Enum.any?(event.quests, fn q -> String.contains?(String.downcase(q.name), needle) end)
  end

  # Watchlisted events first, then active, then past. Each input sublist is
  # already newest-first (the context orders by date desc), and `sort_by/2` is
  # stable, so that ordering is preserved within each group.
  defp sort_events(events) do
    Enum.sort_by(events, fn e -> {watchlist_rank(e), status_rank(e)} end)
  end

  defp watchlist_rank(%{watchlisted?: true}), do: 0
  defp watchlist_rank(_), do: 1

  defp status_rank(%{status: "active"}), do: 0
  defp status_rank(_), do: 1

  # ── Function components ─────────────────────────────────

  @doc """
  One event quest's expanded walkthrough, projected from its scraped
  manifest (`EftBuddy.Wiki.Projection` shape) - the same objectives /
  guide blocks the Tasks tab renders. `nil` detail means the quest's
  wiki page hasn't been scraped (or failed to), so we say so rather than
  rendering an empty panel.
  """
  attr :detail, :any, default: nil
  # Unique-per-quest prefix for the zoomable images' DOM ids (each lightbox
  # needs a page-unique id). Starts with a letter so it's a valid CSS id.
  attr :dom_prefix, :string, required: true

  def quest_detail(assigns) do
    ~H"""
    <div :if={is_nil(@detail)} class="text-sm text-fog-500 italic">
      Walkthrough isn't available yet - it'll appear here once the wiki page is scraped.
    </div>

    <div :if={@detail} class="space-y-4">
      <img
        :if={@detail.banner && @detail.banner.url}
        src={@detail.banner.url}
        alt=""
        loading="lazy"
        class="border border-line max-h-48 object-contain"
      />

      <div :if={@detail.objectives_text != []}>
        <h5 class="t-label text-[10px] text-amber mb-2">Objectives</h5>
        <ol class="list-decimal list-inside space-y-2 text-sm text-fog-300">
          <li :for={obj <- @detail.objectives_text}>
            {obj.text}
            <div
              :if={Map.get(@detail.objective_images, obj.index, []) != []}
              class="flex flex-wrap gap-3 mt-2"
            >
              <.zoomable_image
                :for={{img, i} <- Enum.with_index(Map.get(@detail.objective_images, obj.index, []))}
                :if={img["url"]}
                id={"#{@dom_prefix}-o#{obj.index}-#{i}"}
                src={img["url"]}
                alt={img["caption"] || ""}
                caption={img["caption"]}
                width={img["width"]}
                height={img["height"]}
              />
            </div>
          </li>
        </ol>
      </div>

      <div :for={{section, si} <- Enum.with_index(@detail.walkthrough)} class="space-y-2">
        <h5 class="t-label text-[10px] text-amber">{section.heading}</h5>
        <%= for {block, bi} <- Enum.with_index(section.blocks) do %>
          <p :if={block.kind == :heading} class="text-sm font-semibold text-fog-200">
            {block.text}
          </p>

          <p :if={block.kind == :prose} class="text-sm text-fog-300 leading-relaxed wrap-break-word">
            {block.text}
          </p>

          <div :if={block.kind == :gallery} class="flex flex-wrap gap-3">
            <.zoomable_image
              :for={{img, ii} <- Enum.with_index(block.images)}
              :if={img.file["url"]}
              id={"#{@dom_prefix}-g#{si}-#{bi}-#{ii}"}
              src={img.file["url"]}
              alt={img.caption || ""}
              caption={img.caption}
              width={img.file["width"]}
              height={img.file["height"]}
            />
          </div>
        <% end %>
      </div>

      <%!-- This quest's own wiki page, which is a different page from the
           event that introduced it. --%>
      <.source_credit
        id={"credit-#{@dom_prefix}"}
        href={@detail.wiki_link}
        contributors={@detail.contributors}
        image_uploaders={@detail.image_uploaders}
        class="pt-2"
      />
    </div>
    """
  end

  @doc "Left indent (rem) for a nested gameplay-change bullet, by depth."
  def change_indent(level) when is_integer(level) and level > 1, do: (level - 1) * 1.25
  def change_indent(_), do: 0.0
end
