defmodule EftBuddyWeb.MapsLive.Show do
  @moduledoc """
  Per-map detail page: lore, raid parameters, bosses (with escorts and
  spawn chances) and the in-app interactive map viewer.

  Spatial data - extracts, transits, keyed doors, hazards, spawns and
  loot containers - is surfaced as clickable markers on the interactive
  map rather than as separate lists; each key / item-gated marker links
  to the Items tab and each transit links to that map's own detail page.
  """

  use EftBuddyWeb, :live_view

  alias EftBuddy.Attribution
  alias EftBuddy.Maps
  alias EftBuddy.Maps.Assets
  alias EftBuddyWeb.MapsLive.Markers

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Maps.get_map_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That map doesn't exist.")
         |> push_navigate(to: ~p"/maps")}

      map ->
        viewer = build_viewer_config(map)

        socket =
          socket
          |> assign(:page_title, map.name)
          |> assign(
            :page_description,
            "#{map.name} in Escape from Tarkov: raid time, bosses and an interactive map with extracts, transits, keyed doors and hazards."
          )
          |> assign(:active, :maps)
          |> assign(:map, map)
          |> assign(:map_viewer, viewer)

        {:ok, push_viewer_data(socket, map, viewer)}
    end
  end

  # Maps detail derives nothing from the sidebar pings / client-restore
  # blob, so swallow them rather than letting them warn.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Map viewer + markers ───────────────────────────────

  # The viewer payload is split in two.
  #
  # The *config* below is small and bounded, so it rides in `data-tac` and is
  # present on the dead render as well as the live one — the template branches
  # on it (`@map_viewer`, and its `"projection"` for the credit line), so
  # withholding it would render the static-image fallback panel first and swap
  # it out on connect.
  #
  # The *data* — markers, room labels, marker descriptors — is unbounded
  # (hazards emit one marker per position; Interchange has 77 labels) and is
  # pushed over the socket instead. In an HTML attribute every `"` costs six
  # bytes as `&quot;`, and LiveView re-merges `data-*` on every reconnect even
  # under `phx-update="ignore"`.
  #
  # Three config shapes:
  #   * interactive (SVG or tile) map → the synced projection config plus any
  #     2D/3D static image variants;
  #   * no interactive base but has static renders → an image-only payload
  #     (2D/3D viewer, no markers). `Maps.has_imagery?/1` admits such a map, so
  #     this is a live path for any location whose art upstream hasn't drawn an
  #     interactive version of yet;
  #   * neither → nil (no viewer panel, and the map is hidden anyway).
  defp build_viewer_config(map) do
    variants = map.image_variants || %{}

    case Assets.viewer_payload(map) do
      nil ->
        if map_size(variants) == 0 do
          nil
        else
          %{"projection" => nil, "imageVariants" => variants}
        end

      payload ->
        Map.put(payload, "imageVariants", variants)
    end
  end

  # Only the live mount builds the markers, so the expensive pass runs once
  # rather than on both renders.
  #
  # `push_event/3` from `mount/3` is safe here: LiveView runs `execNewMounted()`
  # before dispatching the join's events, so a hook that registers its
  # `handleEvent` in `mounted()` receives this. It is re-sent on reconnect, so
  # the hook's handler has to be idempotent.
  defp push_viewer_data(socket, map, %{"projection" => projection}) when not is_nil(projection) do
    if connected?(socket) do
      markers = Markers.build(map)

      push_event(socket, "tac:data", %{
        slug: map.normalized_name,
        markers: markers,
        labels: Assets.viewer_labels(map),
        markerTypes: Markers.descriptors(markers)
      })
    else
      socket
    end
  end

  defp push_viewer_data(socket, _map, _viewer), do: socket

  # ── Bosses ─────────────────────────────────────────────
  #
  # Grouping, escort cards and the chance / trigger labels live in
  # `EftBuddy.Maps.Bosses` so the index chips and these cards can't disagree
  # about how many bosses a map has. The templates call them via `Maps.*`.

  @doc "Format a scripted spawn time (seconds from raid start) as `m:ss`."
  def spawn_time_label(seconds) when is_integer(seconds) and seconds >= 0 do
    "#{div(seconds, 60)}:#{String.pad_leading(to_string(rem(seconds, 60)), 2, "0")}"
  end

  def spawn_time_label(_), do: nil

  # ── Raid variants ──────────────────────────────────────

  @doc """
  Raid variants worth showing, base first — or `[]` when the map has only one.

  Factory is the only map with more than one today (day and night differ in raid
  duration, player count, enemies and Tagilla's spawn chance), so most maps fall
  through to the plain header.
  """
  def raid_variants(%{variants: variants}) when is_list(variants) do
    case variants do
      [_single] -> []
      many -> Enum.sort_by(many, &(not &1.base))
    end
  end

  def raid_variants(_), do: []

  # ── View helpers ───────────────────────────────────────

  @doc "URL-safe link into the Items tab for an item name."
  def item_link(name) when is_binary(name), do: "/items?q=" <> URI.encode_www_form(name)
  def item_link(_), do: nil

  @doc """
  Link for the map author's name in the credit line, or `nil` to render it plain.

  `maps.json` gives every SVG map's author (Shebuka) an `authorLink` pointing at
  the `tarkov-dev-svg-maps` repository rather than at a personal profile — the
  same place the credit already links its "contributors" phrase. Two links to
  one destination in one line is noise, so the name renders as plain text there
  and stays a link where it genuinely goes somewhere else (`tarkovbot.eu` for
  Icebreaker, `tarkov.dev` for The Lab and The Labyrinth).

  Trailing slashes are normalised because upstream writes the repo URL with one
  and `EftBuddy.Attribution` holds it without.
  """
  def credit_author_href(%{image_author_link: link}, %{url: url})
      when is_binary(link) and is_binary(url) do
    if String.trim_trailing(link, "/") == String.trim_trailing(url, "/"), do: nil, else: link
  end

  def credit_author_href(_map, _source), do: nil

  @doc """
  Heroicon name for a boss spawn-condition badge. Night-restricted spawns get a
  moon; everything else (switches, levers, scripted waves) gets the bolt.
  """
  def spawn_trigger_icon(trigger) when is_binary(trigger) do
    if String.contains?(String.downcase(trigger), "night"), do: "hero-moon", else: "hero-bolt"
  end

  def spawn_trigger_icon(_), do: "hero-bolt"

  # `raid_duration_label/1` is provided by the shared `EftBuddyWeb.Format`
  # module (imported into every template via `html_helpers/0`).
end
