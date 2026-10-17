defmodule EftBuddyWeb.PriceSparklineTest do
  @moduledoc """
  The sparkline plots one point per price change by time, as a step line over
  the last 48 hours. It used to space points evenly by index, which only
  worked while a point arrived every ten minutes.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EftBuddyWeb.UI

  @hour 3_600_000

  defp now, do: System.system_time(:millisecond)

  defp polyline(points) do
    html = render_component(&UI.price_sparkline/1, points: points)

    case Regex.run(~r/points="([^"]+)"/, html) do
      [_, coords] ->
        for pair <- String.split(coords, " ") do
          [x, y] = String.split(pair, ",")
          {String.to_float(x), String.to_float(y)}
        end

      nil ->
        nil
    end
  end

  test "nothing to draw renders nothing" do
    assert polyline(nil) == nil
    assert polyline([]) == nil
  end

  test "a single price is a flat line across the window to now" do
    coords = polyline([%{"price" => 500, "timestamp" => now() - 10 * @hour}])

    assert [{_x0, y}, {100.0, y}] = coords
  end

  test "a price holds until it changes: the line steps rather than slopes" do
    coords =
      polyline([
        %{"price" => 100, "timestamp" => now() - 24 * @hour},
        %{"price" => 200, "timestamp" => now() - 12 * @hour}
      ])

    # Horizontal at 100's height up to the change, vertical at the change, then
    # 200's height to the right edge.
    assert [{x0, y_low}, {x1, y_low}, {x1, y_high}, {100.0, y_high}] = coords
    assert_in_delta x0, 50.0, 0.2
    assert_in_delta x1, 75.0, 0.2
    assert y_high < y_low
  end

  test "history from before the window starts the line at its left edge" do
    coords =
      polyline([
        %{"price" => 100, "timestamp" => now() - 72 * @hour},
        %{"price" => 200, "timestamp" => now() - 24 * @hour}
      ])

    assert [{+0.0, _}, {x1, _}, {x1, _}, {100.0, _}] = coords
    assert_in_delta x1, 50.0, 0.2
  end
end
