defmodule EftBuddy.Maps.AssetsTest do
  use ExUnit.Case, async: true

  alias EftBuddy.Maps.Assets

  defp map(attrs) do
    Map.merge(
      %{
        normalized_name: "customs",
        projection: "svg",
        transform: [0.239, 168.65, 0.239, 136.35],
        coordinate_rotation: 180.0,
        bounds: [[698.0, -307.0], [-372.0, 237.0]],
        svg_bounds: nil,
        min_zoom: 2,
        max_zoom: 6,
        tile_size: 256,
        tile_path: nil,
        height_range: [-1000.0, 1000.0],
        layers: [],
        labels: [],
        svg_path: "https://assets.tarkov.dev/maps/svg/Customs.svg"
      },
      attrs
    )
  end

  describe "vendored SVGs" do
    test "the ten self-hosted maps resolve to a same-origin path" do
      assert Assets.local_svg_path("customs") == "/images/maps/customs.svg"
      assert length(Assets.vendored_slugs()) == 10
    end

    test "tile maps have no vendored SVG" do
      for slug <- ~w(the-lab the-labyrinth icebreaker) do
        refute Assets.vendored?(slug)
        refute Assets.local_svg_path(slug)
      end
    end
  end

  describe "interactive?/1" do
    test "true for a map with a base and the projection maths" do
      assert Assets.interactive?(map(%{}))
    end

    test "false without a projection" do
      refute Assets.interactive?(map(%{projection: nil}))
    end

    test "false when the transform or bounds are missing" do
      refute Assets.interactive?(map(%{transform: nil}))
      refute Assets.interactive?(map(%{bounds: nil}))
    end

    # The gate is structural, with no per-map exclusion list: Icebreaker's
    # upstream numbers are rough, but that is a calibration problem in the data,
    # not a reason to withhold the interactive map.
    test "true for a tile map regardless of how well upstream calibrated it" do
      assert Assets.interactive?(
               map(%{
                 normalized_name: "icebreaker",
                 projection: "tile",
                 tile_path:
                   "https://assets.tarkov.dev/maps/icebreaker/06_infirmary/{z}/{x}/{y}.png"
               })
             )
    end
  end

  describe "viewer_payload/1" do
    test "an SVG map prefers the vendored copy over the upstream URL" do
      payload = Assets.viewer_payload(map(%{}))

      assert payload["projection"] == "svg"
      assert payload["svgUrl"] == "/images/maps/customs.svg"
      refute Map.has_key?(payload, "tileUrl")
    end

    # Icebreaker's ship is roughly 1:7, so it draws as a tall ribbon; the
    # viewer lays it on its side. This is a *display* rotation and must stay a
    # separate key from `rotation` (coordinate_rotation), which aligns game
    # coordinates to the art and would desync the markers if it were reused.
    test "the display rotation is per-map and distinct from coordinate_rotation" do
      icebreaker =
        map(%{
          normalized_name: "icebreaker",
          projection: "tile",
          tile_path: "https://assets.tarkov.dev/maps/icebreaker/06_infirmary/{z}/{x}/{y}.png"
        })

      payload = Assets.viewer_payload(icebreaker)

      assert payload["viewRotation"] == 90
      assert payload["rotation"] == 180.0

      assert Assets.viewer_payload(map(%{}))["viewRotation"] == 0
      assert Assets.view_rotation("customs") == 0
    end

    # Labels are unbounded (Interchange has 77), so they ride the socket with
    # the markers rather than the `data-tac` attribute this payload becomes.
    test "room labels are not in the attribute payload" do
      refute Map.has_key?(Assets.viewer_payload(map(%{})), "labels")

      assert Assets.viewer_labels(map(%{labels: [%{"text" => "Dorms"}]})) == [
               %{"text" => "Dorms"}
             ]

      assert Assets.viewer_labels(%{}) == []
    end

    test "falls back to the upstream SVG for a non-vendored SVG map" do
      payload = Assets.viewer_payload(map(%{normalized_name: "brand-new"}))
      assert payload["svgUrl"] == "https://assets.tarkov.dev/maps/svg/Customs.svg"
    end

    test "a tile map carries the template plus mosaic geometry" do
      payload =
        Assets.viewer_payload(
          map(%{
            normalized_name: "the-labyrinth",
            projection: "tile",
            tile_path: "https://assets.tarkov.dev/maps/labyrinth/main/{z}/{x}/{y}.png",
            # Upstream leaves Labyrinth's tileSize unset; Leaflet's default is 256.
            tile_size: nil
          })
        )

      assert payload["projection"] == "tile"
      assert payload["tileUrl"] =~ "labyrinth/main"
      assert payload["tileSize"] == 256
      assert payload["tileZoom"] == 4
    end

    test "returns nil when there is no usable interactive base" do
      refute Assets.viewer_payload(map(%{projection: nil}))
    end

    test "layers carry their id, svg group, tile template and extents" do
      payload =
        Assets.viewer_payload(
          map(%{
            layers: [
              %{
                "name" => "4th Floor",
                "id" => "4th-floor",
                "svgLayer" => nil,
                "tileUrl" => "https://assets.tarkov.dev/maps/customs_0.16/4th/{z}/{x}/{y}.png",
                "extents" => [%{"height" => [10.0, 20.0], "bounds" => nil}]
              }
            ]
          })
        )

      assert [layer] = payload["layers"]
      assert layer["id"] == "4th-floor"
      assert layer["tileUrl"] =~ "customs_0.16/4th"
      assert layer["tileSize"] == 256
      assert [%{"height" => [10.0, 20.0]}] = layer["extents"]
    end

    test "emits heightRange, which the old snapshot held but never sent" do
      assert Assets.viewer_payload(map(%{}))["heightRange"] == [-1000.0, 1000.0]
    end
  end
end
