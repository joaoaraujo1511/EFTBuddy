defmodule EftBuddyWeb.TasksLiveProgressTest do
  @moduledoc """
  The completed-quest set is the operator's most valuable data and `localStorage`
  is its only durable copy, so the rules governing what gets written back are
  tested directly rather than inferred from the UI.

  The load-bearing case is the first test. It fails on the implementation this
  replaced, where `persist_tasks_progress/1` regenerated the saved list by
  filtering the current catalogue — making the saved record an inner join with
  whatever the sync last wrote, and silently deleting anything that fell out.
  """
  use EftBuddyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures, only: [task: 1]

  alias EftBuddy.Progress
  alias EftBuddyWeb.Plugs.OperatorSession, as: SessionPlug

  defp new_token, do: "tasks-progress-#{System.unique_integer([:positive])}"

  defp conn_for(conn, token) do
    Plug.Test.init_test_session(conn, %{SessionPlug.token_key() => token})
  end

  defp pvp_blob(slice), do: %{"modes" => %{"pvp" => slice}}

  defp toggle_complete(view, task_name) do
    view
    |> element(~s{button[aria-label="Mark #{task_name} complete"]})
    |> render_click()
  end

  test "a completed slug the catalogue cannot resolve survives an unrelated toggle", %{conn: conn} do
    # "shortage" exists; "renamed-upstream" does not — exactly what tarkov.dev
    # produces when it re-tags a quest during an event and `Tasks.Sync` rewrites
    # `normalized_name` in place on the existing row.
    task(%{name: "Shortage", normalized_name: "shortage"})

    {:ok, view, _html} = live(conn_for(conn, new_token()), ~p"/tasks")

    render_hook(
      view,
      "eft:restore",
      pvp_blob(%{"completed_tasks" => ["renamed-upstream"]})
    )

    # Toggling a DIFFERENT quest is what used to destroy the orphan: the whole
    # list was rebuilt from `all_tasks`, which cannot resolve it.
    toggle_complete(view, "Shortage")

    assert_push_event(view, "eft:store", pushed)
    completed = pushed |> Progress.slice(:pvp) |> Map.fetch!("completed_tasks")

    assert "renamed-upstream" in completed,
           "a completed quest that the current catalogue cannot resolve must be " <>
             "carried, not pruned — localStorage is the only durable copy"

    assert "shortage" in completed
  end

  test "an unresolvable slug contributes no completion state to the page", %{conn: conn} do
    # The other half of the contract: carrying the slug must not make the page
    # claim anything about it. It renders as nothing until its quest returns.
    task(%{name: "Shortage", normalized_name: "shortage"})

    {:ok, view, _html} = live(conn_for(conn, new_token()), ~p"/tasks")

    render_hook(view, "eft:restore", pvp_blob(%{"completed_tasks" => ["renamed-upstream"]}))

    html = render_patch(view, ~p"/tasks?status=completed")

    refute html =~ "renamed-upstream"
  end

  test "unchecking removes the slug it was keyed on", %{conn: conn} do
    task(%{name: "Debut", normalized_name: "debut"})

    {:ok, view, _html} = live(conn_for(conn, new_token()), ~p"/tasks")

    render_hook(view, "eft:restore", pvp_blob(%{"completed_tasks" => ["debut"]}))
    toggle_complete(view, "Debut")

    assert_push_event(view, "eft:store", pushed)
    assert pushed |> Progress.slice(:pvp) |> Map.fetch!("completed_tasks") == []
  end

  test "a forged toggle_complete id is a no-op rather than a crash", %{conn: conn} do
    task(%{name: "Debut", normalized_name: "debut"})

    {:ok, view, _html} = live(conn_for(conn, new_token()), ~p"/tasks")

    # Every handle_event clause is reachable by an arbitrary client frame,
    # regardless of what the page rendered.
    assert render_click(view, "toggle_complete", %{"id" => "no-such-task"})
    assert render_click(view, "toggle_complete", %{"id" => %{"nested" => "map"}})
    assert render(view) =~ "Debut"
  end
end
