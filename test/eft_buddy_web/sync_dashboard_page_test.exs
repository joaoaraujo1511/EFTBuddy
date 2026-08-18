defmodule EftBuddyWeb.SyncDashboardPageTest do
  @moduledoc """
  The syncs page lives behind an SSH tunnel on an endpoint the test suite never
  starts, so without this its first real render would happen in production —
  during whatever incident prompted someone to open it.

  Rendering it here catches what a compile cannot: a helper with no clause for
  the value it is actually handed. Every column on this page has a "nothing has
  happened yet" case, and a freshly-booted node hits all of them at once.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias EftBuddy.Sync.Reporter
  alias EftBuddyWeb.SyncDashboardPage

  setup do
    Reporter.reset_status()
    on_exit(&Reporter.reset_status/0)
    :ok
  end

  defp render_page do
    freshness = EftBuddy.Sync.Freshness.evaluate()
    status = Reporter.status()
    schedule = Reporter.schedule()

    render_component(&SyncDashboardPage.render/1,
      freshness: freshness,
      families: Enum.sort_by(freshness.syncs, fn {prefix, _} -> prefix end),
      feeds: feeds(status, schedule),
      never_run: 9
    )
  end

  # Mirrors `SyncDashboardPage.feed_rows/2`, which is private. Duplicated rather
  # than exposed: the page's job is rendering, and widening its API so a test can
  # reach in would be the wrong trade.
  defp feeds(status, schedule) do
    Enum.map(EftBuddy.Sync.Registry.all(), fn feed ->
      label = feed.mod.label()

      %{
        label: label,
        upstream: feed.upstream,
        bootstrap: feed.bootstrap,
        interval_ms: feed.mod.effective_interval_ms(),
        stagger_ms: feed.mod.stagger_ms(),
        run: Map.get(status, label),
        next: Map.get(schedule, label)
      }
    end)
  end

  test "renders on a node where nothing has run or armed anything" do
    # The state every deploy passes through, and the one with the most `nil`s:
    # no run records, no schedule rows, every age and next-run absent.
    html = render_page()

    assert html =~ "Families"
    assert html =~ "Feeds"

    # A feed with no run record must say so, not render a blank cell that reads
    # as "fine".
    assert html =~ "never"
    assert html =~ "not armed"
  end

  test "lists every registered feed, including ones that have never reported" do
    # The whole argument for building this table from the registry instead of
    # from the status table: a table of what has run cannot show what has not.
    html = render_page()

    for feed <- EftBuddy.Sync.Registry.all() do
      assert html =~ feed.mod.label(),
             "#{inspect(feed.mod)} is registered but absent from the feeds table"
    end
  end

  test "shows when a feed plans to run next once it has armed a timer" do
    Reporter.record_next_run("EventsSync", :timer.hours(3))

    html = render_page()

    # "3h 0m", via `duration_s/1`. The number that would have made the stranded
    # Fandom scrapes obvious at a glance.
    assert html =~ "in 3h"
    refute html =~ "in 0s"
  end

  test "renders a run record next to its feed" do
    Reporter.attach_telemetry()
    Reporter.with_run("MapsSync", fn -> {:ok, %{maps: 12}} end)

    html = render_page()

    assert html =~ "ok"
    assert html =~ "MapsSync"
  end

  test "an overdue tick renders as overdue rather than as a negative duration" do
    # `duration_s/1` has no clause for a negative, so a planned moment that has
    # passed must be routed through `relative/1`'s own branch — this asserts the
    # page does not simply hand it the raw number.
    Reporter.record_next_run("MapsSync", 0)
    Process.sleep(1_100)

    assert render_page() =~ "overdue"
  end
end
