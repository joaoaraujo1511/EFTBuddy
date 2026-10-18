defmodule EftBuddyWeb.SyncAwareTest do
  @moduledoc """
  Pages follow the syncs that feed them (audit L18), and their load state is an
  assign rather than a template-local variable (audit M17).

  A page that mounted before its feed had synced used to sit in standby until the
  visitor reloaded it by hand, and a database outage on the Maps page looked
  exactly like "still syncing", with no Retry.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  alias EftBuddy.Sync.Reporter
  alias EftBuddyWeb.LoadState

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  defp finished(label, outcome \\ :ok) do
    Phoenix.PubSub.broadcast(
      EftBuddy.PubSub,
      Reporter.sync_topic(),
      {:sync_finished, label, outcome}
    )
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Render after the page has handled the broadcast. Handling it can send the page
  # `:reload_after_sync`, which joins its mailbox behind anything already queued;
  # a synchronous call first puts the reload ahead of the render.
  defp render_after_sync(view) do
    :sys.get_state(view.pid)
    render(view)
  end

  test "Reporter announces each finished run, without the mode suffix" do
    Phoenix.PubSub.subscribe(EftBuddy.PubSub, Reporter.sync_topic())

    ExUnit.CaptureLog.capture_log(fn ->
      Reporter.with_run("TasksSync:pve", fn -> {:ok, %{}} end)
    end)

    assert_receive {:sync_finished, "TasksSync", :ok}
  end

  test "a page in standby fills in when its feed finishes", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/maps")
    assert html =~ ~s(aria-busy="true")
    assert assigns(view).load_state == :loading

    game_map(%{name: "Customs", normalized_name: "customs"})
    finished("MapsSync")

    assert render_after_sync(view) =~ "Customs"
    assert assigns(view).load_state == :loaded
  end

  test "a page already showing data is not reloaded under the reader", %{conn: conn} do
    task(%{name: "Debut"})
    {:ok, view, _html} = live(conn, ~p"/tasks")

    task(%{name: "Arrived Later"})
    finished("TasksSync")

    html = render_after_sync(view)
    assert html =~ "Debut"
    refute html =~ "Arrived Later"
  end

  test "a feed that is not this page's is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maps")

    game_map(%{name: "Customs", normalized_name: "customs"})
    finished("TasksSync")

    refute render_after_sync(view) =~ "Customs"
  end

  test "a failed read is an error with a Retry, not a spinner" do
    assert LoadState.resolve(false, :maps, true) == :error
    assert LoadState.resolve(true, :maps, true) == :loaded
    assert LoadState.resolve(false, :maps, false) == :loading
  end

  test "each feed's last success is tracked across modes" do
    ExUnit.CaptureLog.capture_log(fn ->
      Reporter.with_run("PricesSync:regular", fn -> {:ok, %{}} end)
      Reporter.with_run("PricesSync:pve", fn -> {:error, :boom} end)
    end)

    assert %DateTime{} = LoadState.last_ok_at()["PricesSync"]
    refute Map.has_key?(LoadState.last_ok_at(), "MapsSync")
  end
end
