defmodule EftBuddy.Items.SyncPricesPerModeTest do
  @moduledoc """
  The price tick fetches and writes each game mode on its own (audit M11).
  Both fetches used to share one `with`, so a PVE document that failed to
  download also skipped the PVP write, though PVP had arrived fine.
  """
  use EftBuddy.DataCase, async: false

  import EftBuddy.Fixtures

  alias EftBuddy.Items.ItemPrice
  alias EftBuddy.Items.Sync
  alias EftBuddy.Sync.Reporter
  alias EftBuddy.TarkovFixtures

  @dir Path.expand("../../fixtures/tarkov", __DIR__)

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)

    # Every priced item in the fixture exists locally, as after a full sync.
    for {id, it} <- TarkovFixtures.doc("regular", "items")["data"]["items"],
        is_integer(it["lastLowPrice"]),
        do: item(%{external_id: id, normalized_name: id})

    :ok
  end

  test "a failed PVE fetch still writes PVP prices, and the run reports the failure" do
    Req.Test.stub(EftBuddy.TarkovApi, fn
      %{request_path: "/pve/items"} = conn ->
        Plug.Conn.send_resp(conn, 503, "upstream unavailable")

      conn ->
        body = File.read!(Path.join(@dir, conn.request_path <> ".json"))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
    end)

    assert {:error, {:partial, [{"regular", _}], [{"pve", _}]}} = Sync.run_prices()

    modes = ItemPrice |> select([p], p.game_mode) |> distinct(true) |> Repo.all()
    assert modes == ["regular"]
  end
end
