defmodule EftBuddyWeb.TasksLiveTest do
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  test "lists tasks and shows per-status counts in the options bar", %{conn: conn} do
    trader = trader(%{name: "Prapor", normalized_name: "prapor"})
    task(%{name: "Debut", trader_id: trader.id})

    {:ok, _view, html} = live(conn, ~p"/tasks")

    assert html =~ "Debut"
    # ALL tab reflects the single task via a count badge.
    assert html =~ ~r/text-\[10px\][^>]*>\s*1\s*</
  end

  test "the COMPLETED filter is reachable and renders its empty state", %{conn: conn} do
    task(%{name: "Debut"})

    {:ok, view, _html} = live(conn, ~p"/tasks")
    html = render_patch(view, ~p"/tasks?status=completed")

    # Nothing is completed yet (no per-player progress), so the count is 0.
    assert html =~ "Completed"
    assert html =~ ~r/text-\[10px\][^>]*>\s*0\s*</
  end
end
