defmodule EftBuddyWeb.TickKeepsPlaceTest do
  @moduledoc """
  Ticking a quest done or starring a quest or item keeps the reader where they
  were: as many rows loaded, the same rows open.

  Every tick used to go through the same reset as a new filter or search, so a
  reader 120 rows down was sent back to the first page with everything
  collapsed after each click (audit §9, "list behaviour").
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures

  # The LiveView's own assigns, so the test can check what is loaded and open
  # without depending on how a row happens to render.
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "Tasks" do
    setup do
      trader = trader(%{name: "Prapor", normalized_name: "prapor"})

      tasks =
        for i <- 1..60 do
          n = String.pad_leading("#{i}", 2, "0")
          task(%{name: "Task #{n}", normalized_name: "task-#{n}", trader_id: trader.id})
        end

      %{tasks: tasks}
    end

    test "a tick keeps the second page loaded and the open row open", %{conn: conn, tasks: tasks} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_hook(view, "load_more", %{})
      assert assigns(view).tasks_loaded == 60

      open = hd(assigns(view).filtered_tasks)
      render_click(view, "toggle_expand", %{"id" => open.id})
      assert MapSet.member?(assigns(view).expanded_ids, open.id)

      other = Enum.find(tasks, &(&1.id != open.id))
      render_click(view, "toggle_watchlist", %{"slug" => other.normalized_name})

      assert assigns(view).tasks_loaded == 60
      assert MapSet.member?(assigns(view).expanded_ids, open.id)

      render_click(view, "toggle_complete", %{"id" => other.id})

      assert assigns(view).tasks_loaded == 60
      assert MapSet.member?(assigns(view).expanded_ids, open.id)
    end

    test "a new search still starts from the first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks")
      render_hook(view, "load_more", %{})

      render_patch(view, ~p"/tasks?q=Task")

      assert assigns(view).tasks_loaded == 50
    end
  end

  describe "Items" do
    setup do
      for i <- 1..60 do
        n = String.pad_leading("#{i}", 2, "0")
        item(%{name: "Item #{n}", normalized_name: "item-#{n}", short_name: "I#{n}"})
      end

      :ok
    end

    test "a star keeps the second page loaded and the open row open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/items")
      render_hook(view, "load_more", %{})
      assert assigns(view).items_loaded == 60

      [open_id | _] =
        EftBuddy.Items.list_all_items(limit: 1, game_mode: :pvp) |> Enum.map(& &1.id)

      render_click(view, "toggle_expand", %{"id" => open_id})
      assert MapSet.member?(assigns(view).expanded_ids, open_id)

      render_click(view, "toggle_watchlist", %{"slug" => "item-42"})

      assert assigns(view).items_loaded == 60
      assert MapSet.member?(assigns(view).expanded_ids, open_id)
      assert Map.has_key?(assigns(view).details_cache, open_id)
    end
  end

  describe "Flea Market" do
    setup do
      for i <- 1..60 do
        n = String.pad_leading("#{i}", 2, "0")
        item(%{name: "Flea #{n}", normalized_name: "flea-#{n}", last_low_price: 1_000 + i})
      end

      :ok
    end

    test "a star keeps the second page loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/flea-market")
      first = assigns(view).items_loaded
      render_hook(view, "load_more", %{})
      loaded = assigns(view).items_loaded
      assert loaded > first

      render_click(view, "toggle_favorite", %{"slug" => "flea-07"})

      assert assigns(view).items_loaded == loaded
    end
  end
end
