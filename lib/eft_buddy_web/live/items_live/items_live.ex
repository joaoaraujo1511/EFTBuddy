defmodule EftBuddyWeb.ItemsLive.Index do
  use EftBuddyWeb, :live_view

  alias EftBuddy.Chapters
  alias EftBuddy.ItemCategories
  alias EftBuddy.Items
  alias EftBuddy.Items.BackgroundColor
  alias EftBuddy.Progress
  alias EftBuddyWeb.ClientBridge

  # Page size for the vertical streaming list. Each row is ~64px so
  # 50 rows ≈ 3200px - comfortably more than a viewport, ensuring
  # `phx-viewport-bottom` always has room to fire.
  @page_size 50

  @valid_scopes ~w(all watchlist hideout quest barter craft)a

  # Key (inside the ACTIVE GAME MODE's slice of the progress blob) the item
  # watchlist is stored under. Read from `@client_state` in `mount/3`, written on
  # every toggle via `ClientBridge.put_progress/2`. Stored as a flat list of
  # stable `normalized_name` slugs so the watchlist survives a reseed -
  # mirroring the Flea Market watchlist. PVP and PVE keep separate lists (see
  # `EftBuddy.Progress`), so a mode flip re-reads it.
  @watchlist_key "items_watchlist"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Items")
      |> assign(
        :page_description,
        "Search the full Escape from Tarkov item database: barters, crafts, flea prices and the quests that need each item."
      )
      |> assign(:active, :items)
      |> assign(:query, "")
      |> assign(:sort, :default)
      |> assign(:scope, :all)
      # Active curated category group id (shared with the Flea Market via
      # `EftBuddy.ItemCategories`); nil means "All categories".
      |> assign(:active_category, nil)
      # The operator's item watchlist - stable `normalized_name` slugs read from
      # `@client_state`, the server-authoritative progress blob assigned by the
      # `EftBuddyWeb.OperatorState` hook before the first render. On a live
      # navigation the stars are therefore correct on first paint; only a cold
      # connect hydrates later, via `{:client_state_restored, ...}`.
      # `watchlist_count` backs the gold tab badge.
      |> then(&assign_favorites(&1, read_favorite_slugs(&1)))
      # Per-scope item counts for the options-bar tab badges. Computed
      # on the connected mount only (the quest/barter/craft scopes touch
      # JSONB + join subqueries, so we keep them off the cheap
      # disconnected render); the badges pop in once connected.
      |> assign(
        :scope_counts,
        if(connected?(socket), do: EftBuddy.Items.scope_counts(socket.assigns.mode), else: %{})
      )
      # Per-item category tokens (`%{item_id => [token]}`) for the
      # coloured pills the list renders next to each name. Populated a
      # page at a time by `reset_items/1` / `load_more` alongside the
      # stream; empty until the first listing loads.
      |> assign(:category_flags, %{})
      |> assign_category_groups()
      # Set of currently-expanded item ids. We allow multiple rows
      # to be open at once (matches how players cross-reference
      # similar items) but the default state is "all collapsed".
      |> assign(:expanded_ids, MapSet.new())
      # Cache: item_id → details map. We pay the DB cost the first
      # time a row is expanded and keep the result for the lifetime
      # of the LiveView, so collapse/re-expand is free.
      |> assign(:details_cache, %{})
      # Empty stream + safe defaults for the pagination assigns the
      # template reads on the first render. The actual listing is
      # loaded by `handle_params/3` (which always runs after mount,
      # even on direct page loads), using the real `?q=` / `?scope=`
      # values from the URL. Doing the load *only* there matches how
      # the Flea Market and Tasks pages work and keeps the URL the
      # single source of truth - without this, hitting
      # `/items?q=Salewa` cold would briefly populate the stream
      # with the unfiltered list during mount and then fail to fully
      # replace it, so the search bar would show "Salewa" but the
      # rows below would stay unfiltered.
      |> stream(:items, [])
      |> assign(:items_loaded, 0)
      |> assign(:end_of_items?, false)

    {:ok, socket}
  end

  # ── URL handling ───────────────────────────────────────

  # Honors `?q=...` and `?scope=...` so the page can be deep-linked
  # from elsewhere (e.g. the Hideout page can link straight to
  # `/items?scope=hideout` to drop the user into the build-cost
  # subset).
  @impl true
  def handle_params(params, _uri, socket) do
    scope = parse_scope(params["scope"])
    category = parse_category(params["category"])
    query = params |> Map.get("q", "") |> to_string() |> String.slice(0, 200)

    socket =
      socket
      |> assign(:scope, scope)
      |> assign(:active_category, category)
      |> assign(:query, query)
      |> reset_items()

    {:noreply, socket}
  end

  # ── Events ─────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: items_path(query, socket.assigns.scope, socket.assigns.active_category),
       replace: true
     )}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: items_path("", socket.assigns.scope, socket.assigns.active_category),
       replace: true
     )}
  end

  def handle_event("toggle_sort", %{"col" => col}, socket) do
    {:noreply, socket |> assign(:sort, next_sort(col, socket.assigns.sort)) |> reset_items()}
  end

  # Add/remove an item from the operator's watchlist. The card's star is
  # flipped instantly client-side (paired `JS.toggle_class`), so here we update
  # the canonical slug list, persist it to localStorage via the `Hud` hook, and
  # re-run the listing so a watchlisted item floats to the top (or leaves the
  # watchlist view). Slugs (stable `normalized_name`) are stored, not DB ids,
  # so a reseed never orphans a saved watchlist.
  def handle_event("toggle_watchlist", %{"slug" => slug}, socket)
      when is_binary(slug) and slug != "" do
    slugs = socket.assigns.favorite_slugs
    new_slugs = if slug in slugs, do: List.delete(slugs, slug), else: [slug | slugs]

    {:noreply,
     socket
     |> assign_favorites(new_slugs)
     |> persist_watchlist()
     |> reset_items()}
  end

  def handle_event("toggle_watchlist", _params, socket), do: {:noreply, socket}

  # Toggle the expanded state of a single row. On *expand* we lazy-
  # load the detail payload (description, needed-by, obtained-from)
  # via `Items.get_item_details/1` and push it into the row's stream
  # entry as `:details`. On *collapse* we just drop the id from the
  # set - the cached details stay in memory so the next expand is
  # instant. Stream-based update so only the affected row re-renders.
  def handle_event("toggle_expand", %{"id" => item_id}, socket) do
    %{expanded_ids: expanded, details_cache: cache} = socket.assigns

    if MapSet.member?(expanded, item_id) do
      new_expanded = MapSet.delete(expanded, item_id)

      socket =
        socket
        |> assign(:expanded_ids, new_expanded)
        |> stream_insert(
          :items,
          refresh_row(
            item_id,
            cache,
            new_expanded,
            socket.assigns.favorite_slugs,
            socket.assigns.category_flags
          )
        )

      {:noreply, socket}
    else
      {details, new_cache} =
        case Map.fetch(cache, item_id) do
          {:ok, cached} ->
            {cached, cache}

          :error ->
            d = Items.get_item_details(item_id, socket.assigns.mode) |> with_related_chapters()
            {d, Map.put(cache, item_id, d)}
        end

      new_expanded = MapSet.put(expanded, item_id)
      item = details && details.item

      # Build the row VM with details + expanded flag and replace
      # the existing stream entry.
      socket =
        socket
        |> assign(:expanded_ids, new_expanded)
        |> assign(:details_cache, new_cache)
        |> stream_insert(:items, %{
          id: item_id,
          item: item,
          details: details,
          expanded?: true,
          watchlisted?: item && item.normalized_name in socket.assigns.favorite_slugs,
          categories: Map.get(socket.assigns.category_flags, item_id, [])
        })

      {:noreply, socket}
    end
  end

  def handle_event("load_more", _params, socket) do
    %{items_loaded: items_loaded, query: query, sort: sort, scope: scope} = socket.assigns

    next_page =
      Items.list_all_items(
        limit: @page_size,
        offset: items_loaded,
        query: query,
        sort: sort,
        scope: scope,
        category_names: ItemCategories.names_for(socket.assigns.active_category),
        game_mode: socket.assigns.mode,
        favorite_slugs: socket.assigns.favorite_slugs
      )

    # Merge the next page's category flags into the accumulated map so
    # `build_row/2` can paint pills on the freshly appended rows.
    new_flags = Items.category_flags_for(Enum.map(next_page, & &1.id), socket.assigns.mode)
    socket = assign(socket, :category_flags, Map.merge(socket.assigns.category_flags, new_flags))

    socket =
      next_page
      |> Enum.reduce(socket, fn item, acc ->
        stream_insert(acc, :items, build_row(item, acc.assigns))
      end)
      |> assign(:items_loaded, items_loaded + length(next_page))
      |> assign(:end_of_items?, end_of_items?(next_page, @page_size))

    {:noreply, socket}
  end

  # ── Sidebar reactions ──────────────────────────────────

  # Prices (and the per-item barter / quest references in the expanded
  # panel) are mode-specific, so a PVP/PVE flip re-runs the listing for
  # the active mode and drops the detail cache (cached panels hold the
  # previous mode's prices/recipes). Faction / PMC level / collapse don't
  # affect the items view, and the localStorage restore message carries
  # no item state - both fall through to the no-op clause.
  @impl true
  def handle_info({:sidebar_state_changed, :mode, _value}, socket) do
    # The scope-tab counts are now mode-aware too (Quest/Barter track
    # the toggle), so recompute them alongside dropping the detail
    # cache and re-streaming the listing for the active mode.
    #
    # The watchlist is re-read too: it's stored per game mode, so the
    # operator's PVE watchlist is a different list from their PVP one.
    {:noreply,
     socket
     |> assign(:details_cache, %{})
     |> assign(:scope_counts, Items.scope_counts(socket.assigns.mode))
     |> assign_favorites(read_favorite_slugs(socket))
     |> reset_items()}
  end

  # The progress blob changed: either a cold connect handing up localStorage for
  # the first time, or another of the operator's tabs editing the watchlist. On a
  # live navigation the blob is already present in `mount/3`, so this no longer
  # fires there. Re-stream page 1 so restored favourites are painted on each
  # row's star (and floated to the top).
  def handle_info({:client_state_restored, state}, socket) when is_map(state) do
    socket = assign(socket, :client_state, state)

    {:noreply,
     socket
     |> assign_favorites(read_favorite_slugs(socket))
     |> reset_items()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Keep the slug list and the tab-badge count in lock-step; they must never
  # disagree, so nothing assigns one without the other.
  defp assign_favorites(socket, slugs) when is_list(slugs) do
    socket
    |> assign(:favorite_slugs, slugs)
    |> assign(:watchlist_count, length(slugs))
  end

  # Persist the watchlist: into the operator's authoritative session AND through
  # to localStorage, as a flat list of `normalized_name` slugs.
  defp persist_watchlist(socket) do
    ClientBridge.put_progress(socket, %{@watchlist_key => socket.assigns.favorite_slugs})
  end

  # Pull the active game mode's persisted watchlist out of the progress blob,
  # defensively: a missing / malformed entry yields an empty list.
  defp read_favorite_slugs(%{assigns: %{client_state: state, mode: mode}}) do
    case Progress.get(state, mode, @watchlist_key) do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  # ── Reset / build helpers ──────────────────────────────

  # Re-runs the listing query from page 1 using the current `:query`,
  # `:sort` and `:scope` assigns, replacing any items already on
  # screen. Resets the expanded set since the visible rows may have
  # changed entirely (e.g. switching scope from :all to :hideout).
  defp reset_items(socket) do
    %{query: query, sort: sort, scope: scope} = socket.assigns

    items =
      Items.list_all_items(
        limit: @page_size,
        offset: 0,
        query: query,
        sort: sort,
        scope: scope,
        category_names: ItemCategories.names_for(socket.assigns.active_category),
        game_mode: socket.assigns.mode,
        favorite_slugs: socket.assigns.favorite_slugs
      )

    # Fresh page → the category-flag map is rebuilt from scratch for
    # exactly the ids now on screen (drops any stale flags from a
    # previous scope/mode/search).
    flags = Items.category_flags_for(Enum.map(items, & &1.id), socket.assigns.mode)

    socket =
      socket
      |> assign(:expanded_ids, MapSet.new())
      |> assign(:details_cache, %{})
      |> assign(:category_flags, flags)

    rows = Enum.map(items, &build_row(&1, socket.assigns))

    socket
    |> stream(:items, rows, reset: true)
    |> assign(:items_loaded, length(items))
    |> assign(:end_of_items?, end_of_items?(items, @page_size))
  end

  # Turn an `%Item{}` into the lightweight VM the row template
  # consumes. We always carry `:details` in the shape the template
  # expects so the template can match on `expanded?` cleanly.
  defp build_row(item, assigns) do
    expanded? = MapSet.member?(assigns.expanded_ids, item.id)

    %{
      id: item.id,
      item: item,
      details: Map.get(assigns.details_cache, item.id),
      expanded?: expanded?,
      watchlisted?: item.normalized_name in assigns.favorite_slugs,
      categories: Map.get(assigns.category_flags, item.id, [])
    }
  end

  # Used after a collapse: rebuild the row VM with `expanded?: false`
  # so the template re-renders without the detail panel.
  defp refresh_row(item_id, cache, expanded_ids, favorite_slugs, category_flags) do
    item =
      cache
      |> Map.get(item_id)
      |> case do
        nil -> nil
        %{item: i} -> i
      end

    %{
      id: item_id,
      item: item,
      details: Map.get(cache, item_id),
      expanded?: MapSet.member?(expanded_ids, item_id),
      watchlisted?: item && item.normalized_name in favorite_slugs,
      categories: Map.get(category_flags, item_id, [])
    }
  end

  # ── URL helper ─────────────────────────────────────────

  @doc """
  Build an `/items` path with the given filters preserved as query
  params. Default values are omitted so the bare `/items` URL stays
  clean when no filters are active.
  """
  def items_path(query, scope, category \\ nil) do
    params =
      []
      |> maybe_put(:scope, scope_param(scope))
      |> maybe_put(:category, category)
      |> maybe_put(:q, query_param(query))

    case params do
      [] -> "/items"
      _ -> "/items?" <> URI.encode_query(params)
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, value}]

  defp scope_param(:all), do: nil
  defp scope_param(scope) when is_atom(scope), do: Atom.to_string(scope)
  defp scope_param(_), do: nil

  defp query_param(""), do: nil
  defp query_param(nil), do: nil
  defp query_param(q) when is_binary(q), do: q

  # ── Parsing ────────────────────────────────────────────

  defp parse_scope(value) when is_binary(value) do
    atom = String.to_existing_atom(value)
    if atom in @valid_scopes, do: atom, else: :all
  rescue
    ArgumentError -> :all
  end

  defp parse_scope(_), do: :all

  # Snap `?category=` to a known curated group id (shared with the Flea
  # Market), or nil ("All categories") for a missing / unknown value.
  defp parse_category(id) when is_binary(id) do
    if ItemCategories.valid_id?(id), do: id, else: nil
  end

  defp parse_category(_), do: nil

  # Build the category filter chips with live per-group counts merged on.
  # Counts are catalog-wide (mode-independent), so they're computed once on the
  # connected mount; the disconnected render gets zeroes and pops in on connect.
  defp assign_category_groups(socket) do
    counts_by_category =
      if connected?(socket), do: Items.item_counts_by_category(), else: %{}

    groups =
      Enum.map(ItemCategories.groups(), fn group ->
        count =
          Enum.reduce(group.categories, 0, fn name, acc ->
            acc + Map.get(counts_by_category, name, 0)
          end)

        Map.put(group, :count, count)
      end)

    assign(socket, :category_groups, groups)
  end

  defp end_of_items?(rows, page_size), do: length(rows) < page_size

  # ── Template helpers ───────────────────────────────────

  @doc false
  def format_duration(seconds) when is_integer(seconds) and seconds > 0 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      m > 0 and s > 0 -> "#{m}m #{s}s"
      m > 0 -> "#{m}m"
      true -> "#{s}s"
    end
  end

  def format_duration(_), do: "-"

  # ── Sentence helpers (expanded panel) ──────────────────

  # Subject-verb agreement for sentences that begin with a number:
  #   "1 needs to be found"   ✓
  #   "3 need to be found"    ✓
  @doc false
  def needs_verb(1), do: "needs"
  def needs_verb(_), do: "need"

  # Quest "needed by" sentence. Three variants depending on the
  # objective's `kind` and `foundInRaid` flag - phrasing matches
  # what we agreed on in chat so the page reads as plain English
  # instead of a column of `× count` chips. Each variant is a full
  # sentence and starts with a capital letter; the leading number
  # is rendered as a digit (`"1 needs..."`) which is fine since
  # the sentence still begins capitalised either way.
  #
  #   * `:item` + FiR  → "N need to be found in raid for the quest"
  #   * `:item`        → "N need to be obtained for the quest"
  #   * `:key`         → "This is needed for the quest"
  #
  # The `:key` line intentionally drops the "as a key" qualifier
  # - keys appear in the panel only because they're keys, the
  # context is already clear from the item being a key in the
  # first place, and the shorter phrasing lines up with how the
  # equivalent line for hideout items reads.
  @doc false
  def quest_needed_sentence(%{kind: :key}) do
    "This is needed for the quest"
  end

  def quest_needed_sentence(%{count: count, found_in_raid: true}) do
    "#{count} #{needs_verb(count)} to be found in raid for the quest"
  end

  def quest_needed_sentence(%{count: count}) do
    "#{count} #{needs_verb(count)} to be obtained for the quest"
  end

  # Hideout "needed for" sentence. Hideout items don't have a
  # found-in-raid concept, so there's only one phrasing. Begins
  # with a digit, so it's already correctly cased.
  @doc false
  def hideout_needed_sentence(%{quantity: q}) do
    "#{q} #{needs_verb(q)} to be obtained for the"
  end

  # Quest "obtained from" sentence - the inverse of
  # `quest_needed_sentence/1`. Reads as a single sentence with the
  # quest name appearing as a clickable link after the verb. We
  # don't differentiate on `phase` (start vs finish) here because
  # the user's question - "where can I get this?" - doesn't change
  # depending on whether the reward drops on accept or turn-in.
  # The phase is still surfaced separately if we ever want it,
  # but a single line keeps the panel scannable.
  @doc false
  def task_reward_sentence(%{quantity: q}) do
    "#{q} can be obtained as a quest reward from"
  end

  # Quest "unlocked from" sentence. The item isn't handed over by
  # the quest - finishing it makes the trader *start selling* the
  # item at the given loyalty level (the API's `offerUnlock`
  # reward). Reads as one sentence with the quest name appended as
  # a link, mirroring the other "tasks" sections:
  #   "Unlocks at Prapor LL2 after completing <quest>"
  @doc false
  def task_unlock_sentence(%{trader_name: trader, level: level}) do
    "Unlocks at #{trader} LL#{level} after completing"
  end

  # ── Cross-page link helpers ────────────────────────────

  # Attach the storyline chapters that reference this item to the
  # detail payload (cached alongside the DB-sourced sections). Computed
  # here rather than in `Items.get_item_details/1` so the Items context
  # stays free of a dependency on the storyline (Chapters) data. No-op for
  # a nil payload (unknown item id).
  #
  # `Chapters.chapters_for_item/1` filters `Chapters.list_chapters/0`, which IS
  # cached and warmed ("chapters.list" in the warm registry), so on a warm node
  # this costs no round trip — only an in-memory scan of ~13 chapters' item
  # lists. An earlier comment here asserted the opposite ("it is NOT an ETS
  # lookup ... it is a query and it runs per expand"); it was describing an
  # older implementation.
  #
  # The scan does re-run `normalize_item_name/1` per item on every expand, which
  # is CPU rather than I/O. Small enough to leave alone.
  defp with_related_chapters(nil), do: nil

  defp with_related_chapters(details) do
    Map.put(details, :related_chapters, Chapters.chapters_for_item(details.item))
  end

  # Link the quest name on the expanded panel back to the Tasks
  # page, pre-filtered to that quest. Both pages already accept
  # `?q=<text>` so the destination renders the right subset.
  @doc false
  def task_search_url(name) when is_binary(name) do
    "/tasks?" <> URI.encode_query(q: name)
  end

  # Link the hideout module name to the Hideout page, pre-filtered
  # to the matching station. The hideout page does case-insensitive
  # contains matching against module names so the bare name works
  # without slug normalization.
  @doc false
  def hideout_search_url(name) when is_binary(name) do
    "/hideout?" <> URI.encode_query(q: name)
  end

  # Link an item icon back to the Items page, search-pre-filtered
  # to that name. Used by the recipe-row tiles inside the
  # barter / craft sections - the user clicks the icon and lands
  # on the Items page row for that item, mirroring how the quest
  # / hideout links work in the rest of the panel.
  @doc false
  def item_search_url(name) when is_binary(name) do
    "/items?" <> URI.encode_query(q: name)
  end

  def item_search_url(_), do: "/items"

  # Pretty-print a hideout module reference for the inline link
  # text - e.g. "Lavatory level 2".
  @doc false
  def hideout_module_label(%{station_name: name, level: lvl}),
    do: "#{name} level #{lvl}"

  # ── Category pills ─────────────────────────────────────

  @doc """
  Collapse a row's category tokens into at most one pill *per domain*
  (quest / barter / craft / hideout), so a versatile item shows a few
  rich pills rather than a swarm of tiny ones. When both sides of a
  domain apply the pill carries both, joined by an ampersand
  (e.g. "CRAFT INPUT & OUTPUT", "QUEST REWARD & REQUIREMENT").

  Colours track the scope-tab tones so the pills read as the same
  taxonomy the tabs use: quest = purple, barter = signal, craft =
  olive, hideout = go. Each pill is `%{variant, main, secondary,
  tooltip}` — `main` is the domain word plus the first side,
  `secondary` the second side (or `nil`); the template joins them with
  a white "&" so a two-use item reads at a glance. Pills are ordered
  quest → barter → craft → hideout.
  """
  def item_category_pills(tokens) when is_list(tokens) do
    set = MapSet.new(tokens)

    hideout =
      if MapSet.member?(set, :needed_for_hideout),
        do: %{variant: :go, main: "HIDEOUT", secondary: nil, tooltip: "Needed for hideout"}

    [
      domain_pill(
        set,
        :purple,
        "QUEST",
        {:obtained_from_quests, "REWARD"},
        {:needed_for_quests, "REQUIREMENT"}
      ),
      domain_pill(
        set,
        :signal,
        "BARTER",
        {:needed_for_barters, "INPUT"},
        {:obtained_from_barters, "OUTPUT"}
      ),
      domain_pill(
        set,
        :olive,
        "CRAFT",
        {:needed_for_crafts, "INPUT"},
        {:obtained_from_crafts, "OUTPUT"}
      ),
      hideout
    ]
    |> Enum.reject(&is_nil/1)
  end

  def item_category_pills(_), do: []

  # Build one domain pill from up to two `{token, label}` sides, keeping
  # only the sides present in `set`. Returns nil when neither applies.
  # `main` is "<PREFIX> <first side>", `secondary` the second side; the
  # template renders the joining "&" in white so a two-use item is easy
  # to spot. The tooltip is the full label, sentence-cased.
  defp domain_pill(set, variant, prefix, side_a, side_b) do
    labels =
      [side_a, side_b]
      |> Enum.filter(fn {token, _label} -> MapSet.member?(set, token) end)
      |> Enum.map(&elem(&1, 1))

    case labels do
      [] ->
        nil

      _ ->
        %{
          variant: variant,
          main: prefix <> " " <> hd(labels),
          secondary: Enum.at(labels, 1),
          tooltip: String.capitalize(prefix <> " " <> Enum.join(labels, " & "))
        }
    end
  end

  # Found-in-raid text highlighting (`fir_text/1`) now lives in the shared
  # `EftBuddyWeb.Format` module, imported into every template, so the Items
  # and Tasks pages highlight the phrase identically.

  # ── Function components ────────────────────────────────

  @doc """
  Wiki-style item tile used inside craft and barter recipe rows.

  Renders the item's icon in a small square, with an `×N` quantity
  badge in the top-right corner. The whole tile is a link that
  opens the Items page filtered to that item in a new tab - same
  navigation convention used for quest names and hideout module
  names elsewhere on the panel. The item name is exposed via
  `title=` so hovering shows it (the icon alone isn't always
  recognizable). When `:highlight` is true the tile gets an
  accent border - used for the *output* tile so the eye lands on
  it.

  Attributes:
    * `:item` (required) - `%EftBuddy.Items.Item{}` with at least
      `name` and `icon_link`.
    * `:quantity` (required) - integer to render in the badge.
    * `:highlight` (optional, default false) - accent the tile.
  """
  attr(:item, :any, required: true)
  attr(:quantity, :integer, required: true)
  attr(:highlight, :boolean, default: false)

  def craft_item_tile(assigns) do
    ~H"""
    <a
      href={@item && item_search_url(@item.name)}
      target="_blank"
      rel="noopener"
      class={[
        "relative w-16 h-16 border flex items-center justify-center overflow-hidden shrink-0 hover:border-amber transition-colors",
        if(@highlight, do: "border-amber", else: "border-line")
      ]}
      style={"background-color: #{BackgroundColor.css(@item && @item.background_color)}"}
      title={@item && @item.name}
    >
      <%= if @item && (@item.image_512px_link || @item.icon_link) do %>
        <img
          src={@item.image_512px_link || @item.icon_link}
          alt={@item.name}
          loading="lazy"
          decoding="async"
          class="img-fallback w-full h-full object-contain"
        />
        <span style="display:none;" class="absolute inset-0" aria-hidden="true">
          <span class="absolute inset-0 flex items-center justify-center">
            <.icon name="hero-cube" class="w-5 h-5 text-line-strong" />
          </span>
        </span>
      <% else %>
        <.icon name="hero-cube" class="w-5 h-5 text-line-strong" />
      <% end %>
      <span class="absolute top-0 right-0 t-num text-[10px] text-fog-100 bg-ink-900/90 border-l border-b border-line px-1 leading-tight">
        ×{@quantity}
      </span>
    </a>
    """
  end

  @doc """
  A single craft/barter recipe row (used by all four sections of the detail
  panel). `kind` is `:craft` or `:barter`; `direction` is `:in` (the current
  item is an input - show the recipe's own output) or `:out` (the current item
  is the output - inputs feed it).
  """
  attr :item, :any, required: true
  attr :row, :map, required: true
  attr :kind, :atom, required: true
  attr :direction, :atom, required: true

  def recipe(assigns) do
    ~H"""
    <li class="hud-inset p-4">
      <div class="text-sm text-fog-500 mb-3 leading-relaxed">
        <%= if @kind == :craft do %>
          <a
            href={hideout_search_url(@row.station_name)}
            target="_blank"
            rel="noopener"
            class="text-fog-200 hover:text-amber hover:underline font-medium"
          >
            {@row.station_name} level {@row.station_level}
          </a>
          <span class="mx-1">·</span>
          <span class="text-fog-200">{format_duration(@row.duration)}</span>
        <% else %>
          <span class="text-fog-200 font-medium">{@row.trader_name} level {@row.level}</span>
          <%= if @row.buy_limit do %>
            <span class="mx-1">·</span> Buy limit: <span class="text-fog-200">{@row.buy_limit}</span>
          <% end %>
        <% end %>
        <%= if @row.task_unlock_name do %>
          <span class="mx-1">·</span>
          <%= if @row.task_unlock_trader_name do %>
            After completing <span class="text-fog-200">{@row.task_unlock_trader_name}</span> task
          <% else %>
            Unlocked by:
          <% end %>
          <a
            href={task_search_url(@row.task_unlock_name)}
            target="_blank"
            rel="noopener"
            class="text-amber hover:underline"
          >
            {@row.task_unlock_name}
          </a>
        <% end %>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <.craft_item_tile
          :for={r <- @row.required}
          item={r.item}
          quantity={r.quantity}
          highlight={(@direction == :in and r.item) && @item && r.item.id == @item.id}
        />
        <%= if @direction == :out do %>
          <span class="text-amber mx-1 text-lg leading-none">&rarr;</span>
          <.craft_item_tile item={@item} quantity={@row.output_quantity} highlight={true} />
        <% else %>
          <%= if @row.output do %>
            <span class="text-amber mx-1 text-lg leading-none">&rarr;</span>
            <.craft_item_tile item={@row.output.item} quantity={@row.output.quantity} />
          <% end %>
        <% end %>
      </div>
    </li>
    """
  end
end
