defmodule EftBuddyWeb.MapsLive.Index do
  @moduledoc """
  The Maps tab index: a searchable grid of every in-game location with a
  quick summary (raid time, player count, bosses, quest count). Each card
  links through to the per-map detail page.

  Data comes from `EftBuddy.Maps`, populated by `EftBuddy.Maps.Sync`.
  Reads are wrapped defensively so a transient DB outage renders an
  empty grid rather than crashing the page (mirrors the Storyline
  LiveView).
  """

  use EftBuddyWeb, :live_view

  alias EftBuddy.Maps
  alias EftBuddy.Maps.Assets

  @impl true
  def mount(_params, _session, socket) do
    # Defer the DB reads to the connected mount so the disconnected static
    # render doesn't run the same queries a second time. Until then the grid
    # is empty and the template shows the shared standby panel.
    {maps, counts} = if connected?(socket), do: load_maps(), else: {[], %{}}

    {:ok,
     socket
     |> assign(:page_title, "Maps")
     |> assign(
       :page_description,
       "Every Escape from Tarkov map with raid times, player counts and bosses, plus interactive extract, transit, key and hazard markers."
     )
     |> assign(:active, :maps)
     |> assign(:query, "")
     |> assign(:active_status, "all")
     |> assign(:maps, maps)
     |> assign(:quest_counts, counts)
     |> assign_visible_maps()}
  end

  # The search query lives in the URL (?q=) so views are shareable,
  # refreshable and back/forward-navigable. `handle_params/3` is the
  # single source of truth; the search box just patches the URL.
  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> to_string() |> String.slice(0, 200)
    status = params |> Map.get("status", "all") |> to_string() |> resolve_status()

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:active_status, status)
     |> assign_visible_maps()}
  end

  # Derive the visible map grid (search) into an assign so the template stays
  # declarative - the filtering pipeline lives here, not in the HEEx.
  # Recomputed on mount and on every search change (handle_params).
  #
  # The tab counts are derived from the *searched* set, not from every map: with
  # `?q=cust` active the "All" tab used to report the full roster while the grid
  # below it showed one card. They're assigns rather than inline `<% %>` in the
  # template so HEEx change tracking still works.
  defp assign_visible_maps(socket) do
    searched = filter_maps(socket.assigns.maps, socket.assigns.query)
    keyed = Enum.count(searched, &keyed?/1)

    socket
    |> assign(:visible_maps, filter_status(searched, socket.assigns.active_status))
    |> assign(:status_counts, %{
      all: length(searched),
      open: length(searched) - keyed,
      keyed: keyed
    })
  end

  # Snap unknown values back to "all".
  defp resolve_status(s) when s in ["open", "keyed"], do: s
  defp resolve_status(_), do: "all"

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket, to: maps_path(query, socket.assigns.active_status), replace: true)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: maps_path("", socket.assigns.active_status), replace: true)}
  end

  # The operator HUD (faction/level/mode/karma) pings every LiveView via
  # `{:sidebar_state_changed, ...}` and the client bridge forwards a
  # `{:client_state_restored, ...}` blob on connect. The Maps index derives
  # nothing from either, so swallow them rather than letting them warn.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── View helpers ───────────────────────────────────────

  @doc "Builds a `/maps` path preserving the active search query + status filter."
  def maps_path(query, status \\ "all") do
    params =
      []
      |> then(fn p -> if query in [nil, ""], do: p, else: p ++ [q: query] end)
      |> then(fn p -> if status in [nil, "", "all"], do: p, else: p ++ [status: status] end)

    case params do
      [] -> ~p"/maps"
      _ -> ~p"/maps?#{params}"
    end
  end

  @doc "Case-insensitive substring filter over map name / normalized name."
  def filter_maps(maps, ""), do: maps

  def filter_maps(maps, query) when is_binary(query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      maps
    else
      Enum.filter(maps, fn map ->
        String.contains?(String.downcase(map.name || ""), q) or
          String.contains?(String.downcase(map.normalized_name || ""), q)
      end)
    end
  end

  @doc """
  Filter by entry requirement.

  This bar used to be a placeholder labelled All / Available / Locked that
  tracked its selection in the URL but filtered nothing, with a hardcoded zero
  on "Locked". It now filters on a real property: whether the raid needs an
  access key to enter (The Lab, The Labyrinth and Terminal do).
  """
  def filter_status(maps, "open"), do: Enum.reject(maps, &keyed?/1)
  def filter_status(maps, "keyed"), do: Enum.filter(maps, &keyed?/1)
  def filter_status(maps, _), do: maps

  @doc "Whether a map requires an access key to enter."
  def keyed?(%{access_keys: keys}) when is_list(keys), do: keys != []
  def keyed?(_), do: false

  @doc "Quest count for a map (0 when none / not yet synced)."
  def quest_count(counts, map_id), do: Map.get(counts, map_id, 0)

  @doc """
  Best available preview image URL for a map card, or `nil` when the map has no
  imagery at all.

  Always prefers the *interactive* base so cards stay visually consistent with
  the map you get on the detail page: the vendored same-origin SVG, then the
  remote SVG, then a tile map's zoom-0 tile. Only maps with no interactive base
  fall through to a flat 2D / 3D render.

  The tile step matters because The Lab, The Labyrinth and Icebreaker have no
  SVG at all, so they previously skipped straight to their flat render and
  previewed as something you never actually see in the viewer.
  """
  def preview_image(map) do
    Assets.local_svg_path(map.normalized_name) ||
      map.svg_path ||
      tile_thumbnail(map) ||
      variant_url(map, "2d") ||
      variant_url(map, "3d")
  end

  # Zoom 0 of a tile pyramid is a single tile holding the whole map, which makes
  # a ready-made thumbnail for one request instead of a mosaic.
  #
  # Gated on `Assets.interactive?/1` so the card matches the detail page: a map
  # whose projection we don't trust falls through to its flat render, which is
  # what the viewer will show.
  defp tile_thumbnail(%{tile_path: path} = map) when is_binary(path) do
    if Assets.interactive?(map) do
      path
      |> String.replace("{z}", "0")
      |> String.replace("{x}", "0")
      |> String.replace("{y}", "0")
    end
  end

  defp tile_thumbnail(_), do: nil

  defp variant_url(map, kind) do
    case map.image_variants do
      %{^kind => [%{"url" => url} | _]} when is_binary(url) -> url
      _ -> nil
    end
  end

  # `raid_duration_label/1` is provided by the shared `EftBuddyWeb.Format`
  # module (imported into every template via `html_helpers/0`).

  defp load_maps do
    maps = Maps.list_maps()
    counts = Maps.quest_counts()
    {maps, counts}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] -> {[], %{}}
  end
end
