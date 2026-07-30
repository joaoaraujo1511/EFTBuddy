defmodule EftBuddyWeb.TasksLiveQueryCountTest do
  @moduledoc """
  `/tasks` is the landing page (`/` redirects to it) and every route lives in one
  `live_session`, so a `<.link navigate>` into it is a full remount. Its mount
  cost therefore sets the whole app's concurrency ceiling against a default pool
  of ten connections.

  It used to issue one `Repo.exists?` per task per wiki lookup slug — 500-1200
  round trips on a real catalogue — under a comment describing an ETS-backed wiki
  layer that had been migrated to Postgres.

  The absolute number is not the invariant worth pinning; it moves whenever a
  legitimate query is added. What must never come back is the SHAPE: mount cost
  growing with the size of the catalogue.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures, only: [task: 1, trader: 1]

  alias EftBuddy.Repo
  alias EftBuddy.Wiki.QuestPage

  defp seed(range, trader) do
    for n <- range do
      slug = "quest-#{n}"
      task(%{name: "Quest #{n}", normalized_name: slug, trader_id: trader.id})

      # Half the quests carry wiki content, so both branches of the badge lookup
      # are exercised: a hit short-circuits after one slug, a miss tries all three.
      if rem(n, 2) == 0 do
        %QuestPage{}
        |> QuestPage.changeset(%{
          normalized_name: slug,
          name: "Quest #{n}",
          wip: false,
          content: %{"task_name" => "Quest #{n}", "sections" => []}
        })
        |> Repo.insert!()
      end
    end
  end

  # Count Repo queries issued while `fun` runs. Ecto emits one telemetry event
  # per query, which is the only way to observe this without a query log.
  defp count_queries(fun) do
    test = self()
    handler = {__MODULE__, System.unique_integer([:positive])}

    :telemetry.attach(
      handler,
      [:eft_buddy, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test, {handler, :query}) end,
      nil
    )

    try do
      fun.()
      drain(handler, 0)
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, acc) do
    receive do
      {^handler, :query} -> drain(handler, acc + 1)
    after
      0 -> acc
    end
  end

  test "mount cost does not grow with the number of tasks", %{conn: conn} do
    trader = trader(%{name: "Prapor", normalized_name: "prapor"})

    seed(1..4, trader)
    small = count_queries(fn -> {:ok, _view, _html} = live(conn, ~p"/tasks") end)

    seed(5..44, trader)
    large = count_queries(fn -> {:ok, _view, _html} = live(conn, ~p"/tasks") end)

    assert large == small,
           """
           A /tasks mount issued #{large} queries with 44 tasks but #{small} with 4. \
           Mount cost must be independent of catalogue size — per-task queries in \
           `to_view_model/2` are what made this page the app's concurrency ceiling. \
           See `load_task_data/1`.
           """

    # A floor as well as a shape check: if someone "fixes" this by removing the
    # data load entirely, `large == small` would still hold at zero.
    assert small > 0
  end

  test "a mount stays in single digits of queries", %{conn: conn} do
    # Deliberately loose. This is a smoke ceiling, not a spec — it catches an
    # accidental N+1 reappearing without failing on every legitimate new query.
    trader = trader(%{name: "Prapor", normalized_name: "prapor"})
    seed(1..20, trader)

    assert count_queries(fn -> {:ok, _view, _html} = live(conn, ~p"/tasks") end) < 15
  end
end
