defmodule EftBuddy.Maps.Assets do
  @moduledoc """
  The genuinely *local* half of interactive-map rendering.

  Projection config — `transform`, `coordinate_rotation`, `bounds`,
  `svg_bounds`, zoom range, floor `layers` with their height extents, and room
  `labels` — is no longer kept here. It is synced per map from tarkov-dev's
  `src/data/maps.json` into `maps` columns (see `EftBuddy.Maps.Sync`), because
  the hand-copied snapshot this module used to hold had silently drifted from
  upstream: The Lab had lost its "Technical" floor, Customs its "4th Floor",
  Reserve four upper floors, and every map's labels were discarded entirely.

  What remains is what upstream cannot tell us:

    * **Which SVGs we self-host.** The 10 maps below are vendored under
      `priv/static/images/maps/<slug>.svg` so they load same-origin instead of
      hot-linking tarkov.dev. They are the styled variants tarkov.dev serves,
      derived from [tarkov-dev-svg-maps](https://github.com/the-hideout/tarkov-dev-svg-maps)
      (CC BY-NC-SA 4.0) — see that directory's `ATTRIBUTION.md`.
    * **The tile mosaic zoom.** Tile maps (The Lab, The Labyrinth, Icebreaker)
      are raster pyramids hot-linked from `assets.tarkov.dev`. Upstream states a
      `minZoom`/`maxZoom` range for the *viewer*, but not which pyramid level to
      lay out as a flat mosaic — that is our rendering choice.
  """

  # Slugs with a vendored, same-origin SVG under priv/static/images/maps/.
  # Everything else either uses a hot-linked tile pyramid or has no
  # interactive base at all.
  @vendored ~w(
    customs
    factory
    ground-zero
    interchange
    lighthouse
    reserve
    shoreline
    streets-of-tarkov
    terminal
    woods
  )

  # Pyramid level rendered as a full 2^n x 2^n mosaic. 4 gives good resolution
  # at 256 tiles, most of which are blank edge tiles the browser skips.
  @default_tile_zoom 4

  # Degrees counter-clockwise to rotate a map for *display*. Purely a viewing
  # choice, and deliberately distinct from `coordinate_rotation`, which aligns
  # game coordinates to the orientation the art was pre-rendered in — rotating
  # that instead would desync the markers from the art.
  #
  #   * `icebreaker` — the ship is roughly 1:7 (entities span x 23.3 by z 160.7),
  #     so it draws as a tall ribbon. Laid on its side it suits a landscape
  #     viewport far better.
  #
  # Tile maps only: the mapping in the client assumes the square mosaic.
  @view_rotation %{"icebreaker" => 90}

  @doc "Display rotation in degrees counter-clockwise, or 0."
  def view_rotation(slug), do: Elixir.Map.get(@view_rotation, slug, 0)

  @doc "Whether we self-host an SVG for this slug."
  def vendored?(slug) when is_binary(slug), do: slug in @vendored
  def vendored?(_), do: false

  @doc "The curated list of slugs with a vendored SVG."
  def vendored_slugs, do: @vendored

  @doc """
  The same-origin path to the vendored SVG for `slug`, or `nil` when we don't
  host one (tile maps and maps with no interactive base).
  """
  def local_svg_path(slug) do
    if vendored?(slug), do: "/images/maps/#{slug}.svg", else: nil
  end

  @doc "Mosaic zoom level for a tile map."
  def tile_zoom(_slug), do: @default_tile_zoom

  @doc """
  Whether we can render an interactive viewer for this map.

  Purely structural: a base (`svg` or `tile`) plus the projection maths
  (`transform` + `bounds`). Maps that fail this still render their flat 2D/3D
  renders.

  There is deliberately no per-map exclusion list. Icebreaker used to be on one
  — on the strength of a check that used the wrong sign for `scaleY`, which
  both tarkov.dev's `getCRS()` and our own `project()` negate. Upstream's
  Icebreaker numbers are genuinely rough (its `bounds` is a byte-identical copy
  of Factory's, and its `transform` scaleZ overshoots the tile art by ~2.2x),
  but that is a calibration problem to fix in the data, not a reason to hide
  the map.
  """
  def interactive?(%{projection: projection, transform: transform, bounds: bounds}) do
    projection in ["svg", "tile"] and
      is_list(transform) and length(transform) == 4 and
      is_list(bounds)
  end

  def interactive?(_), do: false

  @doc """
  JSON-ready *config* for the client `TacMap` hook, built from the map's synced
  rendering columns: the base map (same-origin SVG url, or tile template plus
  geometry), the toggleable floors, and the projection config the marker
  overlay uses.

  Deliberately small and bounded — it rides in a `data-` attribute, so it is
  paid for on the dead render and again on every reconnect. Everything
  unbounded (markers, room labels) is pushed over the socket instead; see
  `EftBuddyWeb.MapsLive.Show`.

  Returns `nil` when the map has no interactive base — those may still render a
  static 2D/3D image (see `EftBuddyWeb.MapsLive.Show`).
  """
  def viewer_payload(map) do
    if interactive?(map), do: build_viewer_payload(map), else: nil
  end

  @doc """
  Room labels for the viewer, delivered out-of-band with the markers.

  Interchange alone has 77, which is why they don't ride in the attribute.
  """
  def viewer_labels(%{labels: labels}) when is_list(labels), do: labels
  def viewer_labels(_), do: []

  defp build_viewer_payload(map) do
    %{
      "projection" => map.projection,
      "layers" => layer_payload(map),
      "transform" => map.transform,
      "rotation" => map.coordinate_rotation,
      # Display-only rotation, applied *after* projection. Distinct from
      # `rotation` above — see `@view_rotation`.
      "viewRotation" => view_rotation(map.normalized_name),
      "bounds" => map.bounds,
      # Marker projection box: the SVG's own registration bounds when they
      # differ from the tile bounds (Reserve), else nil so the client falls
      # back to `bounds`.
      "svgBounds" => map.svg_bounds,
      "minZoom" => map.min_zoom,
      "maxZoom" => map.max_zoom,
      "heightRange" => map.height_range
    }
    |> Elixir.Map.merge(base_map_fields(map))
  end

  # SVG maps carry `svgUrl`, preferring our vendored copy and falling back to
  # the upstream URL. Tile maps carry the tile template plus geometry.
  defp base_map_fields(%{projection: "tile"} = map) do
    %{
      "tileUrl" => map.tile_path,
      "tileSize" => map.tile_size || 256,
      "tileZoom" => tile_zoom(map.normalized_name)
    }
  end

  defp base_map_fields(map) do
    %{"svgUrl" => local_svg_path(map.normalized_name) || map.svg_path}
  end

  # Floors, as synced. A floor carries either an `svgLayer` (a `<g>` id to
  # highlight) or a `tileUrl` (its own pyramid) — and the two mix on a single
  # map: Customs' 4th floor and Reserve's upper floors are tile overlays on an
  # SVG base. `tileSize`/`tileZoom` ride along so the client can build a tile
  # floor without re-deriving them.
  defp layer_payload(%{layers: layers} = map) when is_list(layers) do
    Enum.map(layers, fn l ->
      %{
        "name" => l["name"],
        "id" => l["id"],
        "svgLayer" => l["svgLayer"],
        "tileUrl" => l["tileUrl"],
        "tileSize" => map.tile_size || 256,
        "tileZoom" => tile_zoom(map.normalized_name),
        "extents" => l["extents"] || []
      }
    end)
  end

  defp layer_payload(_), do: []
end
