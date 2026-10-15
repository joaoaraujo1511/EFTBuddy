defmodule EftBuddy.Maps.SyncPerModeTest do
  @moduledoc """
  Map data per game mode (audit M13). tarkov.dev publishes a maps document per
  mode and PVE differs (boss chances, enemies, extracts, spawns, keys, raid
  length); only the PVP document used to be synced, so PVE players saw PVP
  numbers. Runs the real `EftBuddy.Maps.Sync` on trimmed live documents.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias EftBuddy.Maps
  alias EftBuddy.Maps.{Boss, MapModeDetail}
  alias EftBuddy.Repo
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.TarkovFixtures

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  defp factory(mode),
    do:
      Enum.find(
        Map.values(TarkovFixtures.doc(mode, "maps")["data"]["maps"]),
        &(&1["normalizedName"] == "factory")
      )

  # The headline boss's spawn chance, as each mode's document reports it.
  defp upstream_chance(mode) do
    [boss | _] = factory(mode)["bosses"]
    boss["spawnChance"]
  end

  describe "with both documents" do
    setup do
      TarkovFixtures.stub()
      assert {:ok, _} = EftBuddy.Maps.Sync.do_run()
      :ok
    end

    test "each mode's data is stored under its own mode" do
      for mode <- ["regular", "pve"] do
        assert Repo.aggregate(from(b in Boss, where: b.game_mode == ^mode), :count) > 0
        assert Repo.aggregate(from(d in MapModeDetail, where: d.game_mode == ^mode), :count) > 0
      end
    end

    test "reads return the requested mode's numbers" do
      assert upstream_chance("regular") != upstream_chance("pve"),
             "the fixture should carry a boss whose chance differs by mode"

      for {ui_mode, db_mode} <- [pvp: "regular", pve: "pve"] do
        map = Maps.get_map_by_slug("factory", ui_mode)
        [first | _] = map.bosses
        assert first.spawn_chance == upstream_chance(db_mode)
        en = TarkovFixtures.doc(db_mode, "maps_en")["data"]
        assert map.enemies == Enum.map(factory(db_mode)["enemies"], &Map.get(en, &1, &1))
        assert Enum.all?(map.bosses, &(&1.game_mode == db_mode))
      end
    end

    test "a second run replaces each mode's rows rather than adding to them" do
      count = fn -> Repo.aggregate(Boss, :count) end
      before = count.()

      assert {:ok, _} = EftBuddy.Maps.Sync.do_run()
      assert count.() == before
    end

    test "the map page shows the visitor's mode and follows a mode switch", %{conn: conn} do
      label = &Maps.percent_label(upstream_chance(&1))

      {:ok, view, html} = live(conn, ~p"/maps/factory")
      assert html =~ label.("regular")

      render_click(view, "set_mode", %{"mode" => "pve"})
      assert render(view) =~ label.("pve")
    end
  end

  test "a failed PVE document still writes PVP, and the run reports the failure" do
    dir = Path.expand("../../fixtures/tarkov", __DIR__)

    Req.Test.stub(EftBuddy.TarkovApi, fn
      %{request_path: "/pve/maps"} = conn ->
        Plug.Conn.send_resp(conn, 503, "upstream unavailable")

      %{request_path: "/the-hideout/" <> _} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, File.read!(Path.join(dir, "maps_media.json")))

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, File.read!(Path.join(dir, conn.request_path <> ".json")))
    end)

    assert {:error, {:partial, [{"regular", _}], [{"pve", _}]}} = EftBuddy.Maps.Sync.do_run()
    assert Repo.aggregate(from(b in Boss, where: b.game_mode == "regular"), :count) > 0
    assert Repo.aggregate(from(b in Boss, where: b.game_mode == "pve"), :count) == 0
  end
end
