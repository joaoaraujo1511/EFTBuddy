defmodule EftBuddyWeb.FleaMarketLive.Index do
  use EftBuddyWeb, :live_view

  # Curated category groups shared with the Items page (single source of
  # truth in `EftBuddy.ItemCategories`), evaluated at compile time. Live
  # per-group counts are merged on at mount via
  # `EftBuddy.Items.flea_market_counts_by_category/0`.
  @category_groups EftBuddy.ItemCategories.groups()

  @page_size 40
  @max_items 240

  # Key (inside the shared progress blob) the watchlist is stored under. Read
  # from `@client_state` in `mount/3`, written on every toggle via
  # `ClientBridge.put_progress/2`. Lives inside the ACTIVE GAME MODE's slice, so
  # PVP and PVE keep separate lists (see `EftBuddy.Progress`).
  @favorites_key "flea_favorites"

  alias EftBuddy.Progress
  alias EftBuddyWeb.ClientBridge

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Flea Market")
      |> assign(
        :page_description,
        "Live Escape from Tarkov flea market prices with 24h trends across every tradable item, grouped by category."
      )
      |> assign(:active, :flea_market)
      |> assign(:query, "")
      |> assign(:active_group_id, nil)
      |> assign(:flea_status, :all)
      |> assign(:flea_status_counts, %{all: 0, buyable: 0, locked: 0, watchlist: 0})
      # The operator's watchlist - a list of stable `normalized_name` slugs read
      # from `@client_state`, the server-authoritative progress blob assigned by
      # the `EftBuddyWeb.OperatorState` hook before the first render, so
      # favourites are correct on first paint after a live navigation. Only a
      # cold connect hydrates later, via `{:client_state_restored, ...}`.
      |> then(&assign(&1, :favorite_slugs, read_favorite_slugs(&1)))
      # The global flea unlock level (a hard floor, sourced from the
      # API's `fleaMarket.minPlayerLevel`). Fetched once here and threaded
      # into the per-card lock check so the template never hits the DB in
      # its render loop.
      |> assign(:flea_unlock_level, EftBuddy.Items.flea_unlock_level())
      |> assign_category_counts()
      |> stream(:items, [])

    {:ok, socket}
  end

  # Live per-group counts (flea-eligible items only) for the active game
  # mode, so the category chips show e.g. "Ammo (612)" with the right
  # number for PVP vs PVE. Recomputed on mount and whenever the mode
  # flips. One cheap grouped aggregate; `category_groups` carries the
  # resolved `:count` per group.
  defp assign_category_counts(socket) do
    counts_by_category = EftBuddy.Items.flea_market_counts_by_category(socket.assigns.mode)

    groups_with_counts =
      Enum.map(@category_groups, fn group ->
        count =
          Enum.reduce(group.categories, 0, fn name, acc ->
            acc + Map.get(counts_by_category, name, 0)
          end)

        Map.put(group, :count, count)
      end)

    total_count = groups_with_counts |> Enum.map(& &1.count) |> Enum.sum()

    socket
    |> assign(:category_groups, groups_with_counts)
    |> assign(:total_flea_count, total_count)
  end

  # Per-status counts (All / Buyable / Locked) for the options bar,
  # computed against the current search + category context and the
  # operator's PMC level. Recomputed whenever any of those inputs change.
  defp assign_flea_status_counts(socket) do
    counts =
      EftBuddy.Items.flea_market_status_counts(
        query: socket.assigns.query,
        category_names: category_names_for(socket.assigns.active_group_id),
        game_mode: socket.assigns.mode,
        pmc_level: socket.assigns.pmc_level,
        favorite_slugs: socket.assigns.favorite_slugs
      )

    assign(socket, :flea_status_counts, counts)
  end

  # ── Sidebar reactions ──────────────────────────────────

  # PVP and PVE have separate flea economies, so a mode flip recomputes
  # the per-category counts and re-runs the listing for the active mode.
  # The watchlist is re-read for the same reason: it's stored per game
  # mode, so PVE has its own list. Other sidebar changes fall through to
  # the no-op clause.
  @impl true
  def handle_info({:sidebar_state_changed, :mode, _value}, socket) do
    {:noreply,
     socket
     |> then(&assign(&1, :favorite_slugs, read_favorite_slugs(&1)))
     |> assign_category_counts()
     |> assign_flea_status_counts()
     |> reset_items()}
  end

  # The Buyable / Locked split is computed against the operator's PMC
  # level, so a level change recomputes the status counts and re-runs
  # the listing for the active status filter.
  def handle_info({:sidebar_state_changed, :pmc_level, _value}, socket) do
    {:noreply, socket |> assign_flea_status_counts() |> reset_items()}
  end

  # The progress blob changed: either a cold connect handing up localStorage for
  # the first time, or another of the operator's tabs editing the watchlist. On a
  # live navigation the blob is already present in `mount/3`, so this no longer
  # fires there. We own the flea watchlist (`flea_favorites`), so we hydrate it
  # and reflow: the gold watchlist count updates and the listing re-streams with
  # the restored favourites painted on each card's star.
  def handle_info({:client_state_restored, state}, socket) when is_map(state) do
    socket = assign(socket, :client_state, state)

    {:noreply,
     socket
     |> assign(:favorite_slugs, read_favorite_slugs(socket))
     |> assign_flea_status_counts()
     |> reset_items()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  # Read the search query (`?q=`) and category filter (`?category=`)
  # from the URL and reset the items stream on every change. The
  # filter bar and search box both `push_patch` here so the URL is
  # always the source of truth - refreshing the page or sharing the
  # link reproduces exactly the same view.
  def handle_params(params, _uri, socket) do
    query =
      params
      |> Map.get("q", "")
      |> to_string()
      |> String.slice(0, 200)

    active_group_id = resolve_category(params["category"])

    socket =
      socket
      |> assign(:query, query)
      |> assign(:active_group_id, active_group_id)
      |> assign(:flea_status, resolve_status(params["status"]))
      |> assign_flea_status_counts()
      |> reset_items()

    {:noreply, socket}
  end

  # Snap the URL `?status=` to a known flea-status atom, defaulting to
  # `:all` for anything missing / unknown.
  defp resolve_status("buyable"), do: :buyable
  defp resolve_status("locked"), do: :locked
  defp resolve_status("watchlist"), do: :watchlist
  defp resolve_status(_), do: :all

  # Snap the URL value to a known category id, or nil when it's
  # missing / unknown. Defensive: a hostile or stale `?category=`
  # never makes it past this guard into the DB query layer.
  defp resolve_category(nil), do: nil
  defp resolve_category(""), do: nil

  defp resolve_category(id) when is_binary(id) do
    if Enum.any?(@category_groups, &(&1.id == id)), do: id, else: nil
  end

  defp resolve_category(_), do: nil

  @impl true
  # Search input fires `phx-change` on every (debounced) keystroke.
  # We patch the URL so `handle_params/3` re-runs the query; passing
  # `replace: true` keeps the browser history clean - nobody wants
  # 30 history entries for "g", "ge", "gea", "gear".
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: flea_market_path(query, socket.assigns.active_group_id, socket.assigns.flea_status),
       replace: true
     )}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: flea_market_path("", socket.assigns.active_group_id, socket.assigns.flea_status),
       replace: true
     )}
  end

  # Add/remove an item from the operator's watchlist. The card's star
  # is flipped instantly client-side (a `JS.toggle_class` paired with
  # this push), so here we just update the canonical slug list, persist
  # it to localStorage via the `Hud` hook, and refresh the gold count
  # pill. Slugs (stable `normalized_name`) are stored rather than DB ids
  # so a reseed never orphans a saved watchlist - the same rationale the
  # Tasks page uses for completed quests.
  def handle_event("toggle_favorite", %{"slug" => slug}, socket)
      when is_binary(slug) and slug != "" do
    slugs = socket.assigns.favorite_slugs
    new_slugs = if slug in slugs, do: List.delete(slugs, slug), else: [slug | slugs]

    socket =
      socket
      |> assign(:favorite_slugs, new_slugs)
      |> persist_favorites()
      |> assign_flea_status_counts()

    # Reflow the listing on every toggle. On the watchlist view the visible
    # set changed (a card was added or removed); on the other views the query
    # floats favourites to the top (see `apply_flea_favorites_first/3`), so a
    # freshly-starred item jumps to the front of the results, matching the
    # Items tab and the "jumps to the top" promise in the empty-state copy.
    socket = reset_items(socket)

    {:noreply, socket}
  end

  def handle_event("toggle_favorite", _params, socket), do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    %{
      items_loaded: items_loaded,
      query: query,
      active_group_id: active_group_id,
      flea_status: flea_status
    } = socket.assigns

    # The 240-item cap only applies to the unfiltered "live preview" listing.
    # Once a user is searching or filtering by category, they're expressing
    # intent and we let them scroll through all matches.
    filtered? = filtered?(query, active_group_id, flea_status)
    capped? = not filtered? and items_loaded >= @max_items

    if capped? do
      {:noreply, assign(socket, :end_of_items?, true)}
    else
      page_size =
        if filtered? do
          @page_size
        else
          min(@page_size, @max_items - items_loaded)
        end

      next_page =
        EftBuddy.Items.list_flea_market_items(
          limit: page_size,
          offset: items_loaded,
          query: query,
          category_names: category_names_for(active_group_id),
          game_mode: socket.assigns.mode,
          flea_status: flea_status,
          pmc_level: socket.assigns.pmc_level,
          favorite_slugs: socket.assigns.favorite_slugs
        )

      new_total = items_loaded + length(next_page)
      cap_reached? = not filtered? and new_total >= @max_items

      socket =
        socket
        |> stream(:items, next_page)
        |> assign(:items_loaded, new_total)
        |> assign(
          :end_of_items?,
          end_of_items?(next_page, page_size) or cap_reached?
        )

      {:noreply, socket}
    end
  end

  @doc """
  Build a `/flea-market` path with the given filters preserved as query
  params. Used by the search box, the category filter bar and the
  status options bar so toggling one filter never silently drops the
  others.

  Defaults (`""` query, `nil` category, `:all` status) are omitted from
  the URL so the bare `/flea-market` URL stays clean when nothing's set.
  """
  def flea_market_path(query, category_id, status \\ :all) do
    params =
      []
      |> maybe_put(:category, category_id)
      |> maybe_put(:status, status_param(status))
      |> maybe_put(:q, blank_to_nil(query))

    case params do
      [] -> "/flea-market"
      _ -> "/flea-market?" <> URI.encode_query(params)
    end
  end

  defp status_param(status) when status in [:buyable, :locked, :watchlist], do: to_string(status)
  defp status_param(status) when status in ["buyable", "locked", "watchlist"], do: status
  defp status_param(_), do: nil

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, value}]

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  # Re-runs the listing query from page 1 using the current `:query` and
  # `:active_group_id` assigns, replacing any items already on screen.
  # Used by mount and every event that changes a filter so the items list
  # is always in sync with the active filters.
  defp reset_items(socket) do
    %{query: query, active_group_id: active_group_id} = socket.assigns

    items =
      EftBuddy.Items.list_flea_market_items(
        limit: @page_size,
        offset: 0,
        query: query,
        category_names: category_names_for(active_group_id),
        game_mode: socket.assigns.mode,
        flea_status: socket.assigns.flea_status,
        pmc_level: socket.assigns.pmc_level,
        favorite_slugs: socket.assigns.favorite_slugs
      )

    socket
    |> stream(:items, items, reset: true)
    |> assign(:items_loaded, length(items))
    |> assign(:end_of_items?, end_of_items?(items, @page_size))
  end

  # Persist the watchlist: into the operator's authoritative session AND through
  # to localStorage. Stored as a flat list of `normalized_name` slugs.
  defp persist_favorites(socket) do
    ClientBridge.put_progress(socket, %{@favorites_key => socket.assigns.favorite_slugs})
  end

  # Pull the active game mode's persisted watchlist out of the progress blob,
  # defensively: a missing / malformed entry simply yields an empty watchlist
  # rather than crashing the hydration.
  defp read_favorite_slugs(%{assigns: %{client_state: state, mode: mode}}) do
    case Progress.get(state, mode, @favorites_key) do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      _ -> []
    end
  end

  defp filtered?(query, active_group_id, flea_status),
    do: query != "" or active_group_id != nil or flea_status != :all

  # The DB returned fewer rows than we asked for, so there's no next page.
  defp end_of_items?(rows, page_size), do: length(rows) < page_size

  # Pre-compute "group_id" => [category_name, ...] once at compile time.
  @group_id_to_category_names Map.new(@category_groups, &{&1.id, &1.categories})

  defp category_names_for(nil), do: []
  defp category_names_for(group_id), do: Map.get(@group_id_to_category_names, group_id, [])

  # Pre-compute a map of "Category Name" => group_id once at compile time
  # so the template can colour each item's tag in O(1).
  @category_to_group_id Enum.flat_map(@category_groups, fn group ->
                          Enum.map(group.categories, &{&1, group.id})
                        end)
                        |> Map.new()

  @doc false
  def group_id_for_category(nil), do: "others"
  def group_id_for_category(%{name: name}), do: Map.get(@category_to_group_id, name, "others")

  @doc """
  Tailwind classes for the small category chip rendered on each item
  card. Every category uses the same neutral, black-backgrounded tag -
  muted khaki text on a near-black fill with a low-contrast hairline - so
  the pills read as quiet metadata that sits in the HUD rather than a
  rainbow of accent colours competing with the price and status cues.
  Centralised here so the template stays declarative.
  """
  def category_chip_classes(_), do: "text-fog-400 border-line-strong bg-ink-950"

  @doc false
  # Formats an integer ruble amount as "₽1,234,567".
  def format_price(nil), do: "-"

  def format_price(amount) when is_integer(amount) and amount >= 0 do
    "₽" <> thousands(amount)
  end

  @doc false
  # 24h price fluctuation as a percentage. tarkov.dev exposes no
  # ready-made "24h change %" field, so we derive it from the
  # `historical_prices` series the price tick accumulates
  # (`%{"price", "timestamp" => ms}` points, oldest first): compare the
  # most recent flea low against the data point closest to 24h earlier -
  #
  #     pct = (latest − price_24h_ago) / price_24h_ago × 100
  #
  # which is the item's *actual* movement over the trailing day. For a
  # freshly-tracked item whose series doesn't yet span a full day, we
  # fall back to the latest low vs the rolling 24h average (the same two
  # figures the old arrow used) so the card still shows a meaningful
  # number. Returns a float rounded to 1 decimal, or nil when there's
  # nothing to compare.
  @day_ms 86_400_000

  def price_change_24h_pct(item) do
    raw =
      case change_from_history(item.historical_prices) do
        nil -> change_from_avg(item.last_low_price, item.avg_24h_price)
        pct -> pct
      end

    if is_number(raw), do: Float.round(raw, 1), else: nil
  end

  defp change_from_history(points) when is_list(points) do
    numeric =
      Enum.filter(points, fn p ->
        is_number(Map.get(p, "price")) and is_number(Map.get(p, "timestamp"))
      end)

    case numeric do
      [] -> nil
      [_only] -> nil
      _ -> change_over_day(numeric)
    end
  end

  defp change_from_history(_), do: nil

  defp change_over_day(numeric) do
    latest = List.last(numeric)
    cutoff = latest["timestamp"] - @day_ms

    # The most recent point that's at least 24h old (the price "as of"
    # a day ago); the oldest point we have if the whole series is
    # younger than a day. `numeric` is oldest-first, so we walk it in
    # reverse to find the newest qualifying point.
    baseline =
      Enum.find(Enum.reverse(numeric), List.first(numeric), &(&1["timestamp"] <= cutoff))

    pct_change(baseline["price"], latest["price"])
  end

  defp change_from_avg(last_low, avg_24h)
       when is_integer(last_low) and is_integer(avg_24h),
       do: pct_change(avg_24h, last_low)

  defp change_from_avg(_last_low, _avg_24h), do: nil

  # Signed percentage change from `from` → `to`. Nil for a missing or
  # non-positive baseline (can't divide by it meaningfully).
  defp pct_change(from, to) when is_number(from) and is_number(to) and from > 0 do
    (to - from) / from * 100
  end

  defp pct_change(_from, _to), do: nil

  @doc false
  # Up / down / flat for the card arrow + colour, driven by the sign of
  # the (already rounded) 24h fluctuation percentage so the arrow and the
  # number always agree.
  def change_trend(pct) when is_number(pct) do
    cond do
      pct > 0 -> :up
      pct < 0 -> :down
      true -> :flat
    end
  end

  def change_trend(_pct), do: :flat

  @doc false
  # Render the 24h fluctuation as a signed percentage: "+3.4%", "-1.2%",
  # "0.0%". "-" when there's nothing to compare.
  def format_change_pct(nil), do: "-"

  def format_change_pct(pct) when is_number(pct) do
    sign = if pct > 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(pct * 1.0, decimals: 1) <> "%"
  end

  # ── Flea lock + price-history rendering ────────────────

  @doc false
  # Thin template-side delegates to the `EftBuddy.Items` flea-lock
  # helpers so the HEEx stays declarative. `floor` is the page's
  # `@flea_unlock_level` assign (fetched once at mount), so neither call
  # touches the DB inside the per-card render loop.
  def flea_locked?(item, pmc_level, floor),
    do: EftBuddy.Items.flea_locked?(item, pmc_level, floor)

  def effective_flea_level(item, floor),
    do: EftBuddy.Items.effective_flea_level(item, floor)
end
