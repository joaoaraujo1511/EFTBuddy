defmodule EftBuddyWeb.HideoutLiveQueryCountTest do
  @moduledoc """
  The hideout grid's mount cost must not grow with the number of stations.

  This has now been the same bug twice. `build_initial_modules/0` was fixed once
  by batching the per-station requirement fetch, under a comment warning not to
  reintroduce it — but `apply_hideout_levels/2` kept its own copy, calling the
  single-station read once per station, and `mount/3` runs it immediately after
  the batched one. So the batched read was computed, thrown away, and replaced
  with 26 individual ones on essentially every mount.

  It survived because `EftBuddy.Hideout.get_level_requirements/2` was not cached
  at all, so no warming or invalidation mechanism could see it, and because
  against a local Postgres 26 extra round trips cost ~50ms and look fine. At
  ~76ms to a hosted database they are seconds.

  These tests therefore run with the **cache off** (the test env default). That
  is the point: they must prove the read is genuinely batched, not that a cache
  is hiding an N+1 that would return the instant an entry expires.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import EftBuddy.Fixtures, only: [station: 1, station_level: 1, item_requirement: 1, item: 1]

  # Each station gets two levels with an item requirement on each, so the
  # preload branches actually fire — a station with no requirements would let a
  # per-station implementation look constant.
  defp seed_stations(range) do
    for n <- range do
      slug = "station-#{n}"
      station = station(%{name: "Station #{n}", normalized_name: slug})
      item = item(%{name: "Item #{n}", normalized_name: "item-#{n}"})

      for level <- 1..2 do
        row = station_level(%{station_id: station.id, level: level})
        item_requirement(%{level_id: row.id, item_id: item.id, quantity: level * 10})
      end

      slug
    end
  end

  # Counts EVERY repo query, with no pid filter. Ecto runs preloads in separate
  # processes and a LiveView runs in its own process entirely, so a counter
  # filtered on the test pid would read ZERO here and pass vacuously.
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

  # The persisted-levels blob the client hands up after a connect, in the shape
  # `EftBuddy.Progress` reads.
  defp levels_blob(slugs, level) do
    %{"modes" => %{"regular" => %{"hideout" => Map.new(slugs, &{&1, level})}}}
  end

  test "mount cost does not grow with the number of stations", %{conn: conn} do
    seed_stations(1..4)
    small = count_queries(fn -> {:ok, _view, _html} = live(conn, ~p"/hideout") end)

    seed_stations(5..24)
    large = count_queries(fn -> {:ok, _view, _html} = live(conn, ~p"/hideout") end)

    assert large == small,
           """
           A /hideout mount issued #{large} queries with 24 stations but #{small} \
           with 4. Mount cost must be independent of station count — see \
           `populate_all/2` in hideout_live.ex.
           """

    # A floor as well as a shape check: removing the data load entirely would
    # also satisfy `large == small`, at zero.
    assert small > 0
  end

  test "restoring persisted levels does not scale with station count", %{conn: conn} do
    # THE test for the reported bug. The mount-only case above would have passed
    # throughout, because `build_initial_modules/0` was already batched — the
    # per-station fetch lived in `apply_hideout_levels/2`, reached from here and
    # from every game-mode flip.
    small_slugs = seed_stations(1..4)

    small =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/hideout")
        send(view.pid, {:client_state_restored, levels_blob(small_slugs, 1)})
        render(view)
      end)

    large_slugs = small_slugs ++ seed_stations(5..24)

    large =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/hideout")
        send(view.pid, {:client_state_restored, levels_blob(large_slugs, 1)})
        render(view)
      end)

    assert large == small,
           """
           Restoring levels issued #{large} queries for 24 stations but #{small} \
           for 4. `apply_hideout_levels/2` must batch its requirement read.
           """
  end

  test "a game mode flip does not scale with station count", %{conn: conn} do
    small_slugs = seed_stations(1..4)

    small =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/hideout")
        send(view.pid, {:sidebar_state_changed, :mode, :pve})
        render(view)
      end)

    _ = small_slugs ++ seed_stations(5..24)

    large =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/hideout")
        send(view.pid, {:sidebar_state_changed, :mode, :pve})
        render(view)
      end)

    assert large == small,
           "a PVP/PVE flip issued #{large} queries for 24 stations but #{small} for 4"
  end

  test "an upgrade click costs a constant number of queries", %{conn: conn} do
    slugs = seed_stations(1..4)
    first = hd(slugs)

    small =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/hideout")
        render_click(view, "upgrade", %{"slug" => first})
      end)

    seed_stations(5..24)

    large =
      count_queries(fn ->
        {:ok, view, _html} = live(conn, ~p"/hideout")
        render_click(view, "upgrade", %{"slug" => first})
      end)

    assert large == small,
           "an upgrade click issued #{large} queries with 24 stations but #{small} with 4"
  end

  test "a mount stays under a loose ceiling", %{conn: conn} do
    # Deliberately loose. A smoke ceiling, not a spec: it catches an accidental
    # N+1 without failing on every legitimate new query.
    seed_stations(1..20)

    assert count_queries(fn -> {:ok, _view, _html} = live(conn, ~p"/hideout") end) < 20
  end
end
