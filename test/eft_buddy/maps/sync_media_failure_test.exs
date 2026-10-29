defmodule EftBuddy.Maps.SyncMediaFailureTest do
  @moduledoc """
  A failed fetch of tarkov.dev's `maps.json` (the only source of map imagery)
  keeps every map's stored imagery, and fails the run so `/health/sync` sees it
  and the scheduler retries.

  It used to degrade to an empty media map that the upsert wrote over every
  map. `Maps.visible?/1` hides a map with no imagery, so one failed GitHub
  request emptied the Maps page and redirected every map URL until the next
  run, 12 hours later, while the run reported success.
  """
  use EftBuddy.DataCase, async: false

  import ExUnit.CaptureLog

  alias EftBuddy.Maps
  alias EftBuddy.Maps.Map, as: GameMap
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.TarkovFixtures

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)

    TarkovFixtures.stub()
    assert {:ok, _} = EftBuddy.Maps.Sync.do_run()
    EftBuddy.Cache.clear()
    :ok
  end

  defp imagery,
    do: Repo.all(GameMap) |> Map.new(&{&1.normalized_name, {&1.svg_path, &1.image_variants}})

  test "a failed maps.json keeps the imagery, and the maps stay listed" do
    visible = Maps.list_maps(:pvp) |> Enum.map(& &1.normalized_name)
    stored = imagery()
    assert visible != []

    TarkovFixtures.stub(%{TarkovFixtures.maps_media_path() => 503})

    capture_log(fn ->
      send(self(), {:result, EftBuddy.Maps.Sync.do_run()})
    end)

    assert_received {:result, {:error, {:partial, _ok, failures}}}
    assert [{"maps.json", {:unexpected_response, 503, _}}] = failures

    EftBuddy.Cache.clear()
    assert imagery() == stored
    assert Enum.map(Maps.list_maps(:pvp), & &1.normalized_name) == visible
    assert Maps.get_map_by_slug(hd(visible), :pvp)
  end

  test "the run reports the failed maps.json in one readable line" do
    TarkovFixtures.stub(%{TarkovFixtures.maps_media_path() => 503})

    capture_log(fn ->
      send(self(), {:result, EftBuddy.Maps.Sync.do_run()})
    end)

    assert_received {:result, {:error, reason}}
    assert Reporter.describe_error(reason) =~ "maps.json failed (HTTP 503)"
  end

  test "a successful run after the outage still refreshes the imagery" do
    TarkovFixtures.stub(%{TarkovFixtures.maps_media_path() => 503})
    capture_log(fn -> EftBuddy.Maps.Sync.do_run() end)

    Repo.update_all(GameMap, set: [svg_path: "stale.svg"])

    TarkovFixtures.stub()
    assert {:ok, _} = EftBuddy.Maps.Sync.do_run()
    refute Enum.any?(Repo.all(GameMap), &(&1.svg_path == "stale.svg"))
  end
end
