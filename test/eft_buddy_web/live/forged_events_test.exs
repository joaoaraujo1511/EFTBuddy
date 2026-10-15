defmodule EftBuddyWeb.ForgedEventsTest do
  @moduledoc """
  Every `phx-value-*` arrives from the client and can be anything. A handler
  that trusts it either crashes the LiveView (which then remounts, often into
  the same push) or keeps the value in socket state for the life of the
  socket. Regression tests for audit L15 / F7.
  """
  use EftBuddyWeb.ConnCase

  import Phoenix.LiveViewTest

  test "Tasks: expanding an id that names no listed task is a no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tasks")

    for id <- ["not-a-task", Ecto.UUID.generate()] do
      assert render_hook(view, "toggle_expand", %{"id" => id})
    end

    assert render(view)
  end

  test "Items: expanding an unknown item neither crashes nor grows socket state",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/items")

    for id <- ["not-a-uuid", Ecto.UUID.generate()] do
      assert render_hook(view, "toggle_expand", %{"id" => id})
    end

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.details_cache == %{}
    assert MapSet.size(assigns.expanded_ids) == 0
  end

  test "Events: opening a quest that is not listed is a no-op", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/events")

    for id <- ["not-a-uuid", Ecto.UUID.generate()] do
      assert render_hook(view, "toggle_quest", %{"id" => id})
    end

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.details_cache == %{}
    assert MapSet.size(assigns.expanded_ids) == 0
  end

  test "Ammo: sort events for classes and calibers the page doesn't show are ignored",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/ammo")

    for class <- ["x", "99", "", %{"a" => 1}] do
      assert render_hook(view, "toggle_plates_sort", %{"col" => "name", "class" => class})
    end

    assert render_hook(view, "toggle_sort", %{"col" => "damage", "caliber" => "NotACaliber"})

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.plates_sorts == %{}
    assert assigns.sorts == %{}
  end
end
