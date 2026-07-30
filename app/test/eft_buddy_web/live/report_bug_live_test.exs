defmodule EftBuddyWeb.ReportBugLiveTest do
  @moduledoc """
  The bug-report form is the only way an anonymous visitor can write to the
  database, and `bug_reports` is the only table in the app that is not
  re-derivable from an upstream. Its two controls — no identity field, and rate
  limiting — are both tested here.
  """
  use EftBuddyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EftBuddy.Feedback

  @valid %{
    "title" => "Hideout page shows the wrong level",
    "description" => "Bitcoin farm reads level 2 when I have level 3 ticked."
  }

  defp submit(view, params \\ @valid) do
    view |> form("#bug-report-form", bug_report: params) |> render_submit()
  end

  test "collects no identity field", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/report-bug")

    refute html =~ "reporter_name"
    refute html =~ "Callsign"
    refute html =~ "How should we credit you"
  end

  test "persists a valid report", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/report-bug")

    submit(view)

    assert [report] = Feedback.list_bug_reports()
    assert report.title == @valid["title"]
  end

  test "refuses a second submission inside the cooldown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/report-bug")

    submit(view)
    assert length(Feedback.list_bug_reports()) == 1

    # "Report another" clears the confirmation panel but must NOT clear the
    # cooldown — otherwise the control is one click away from useless.
    view |> element("button", "Report another") |> render_click()
    html = submit(view, %{@valid | "title" => "A second report"})

    assert html =~ "wait a minute"

    assert length(Feedback.list_bug_reports()) == 1,
           "the cooldown must prevent the insert, not merely warn about it"
  end

  test "an unknown or malformed event is a no-op rather than a crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/report-bug")

    # `Ecto.Changeset.cast/3` raises on a non-map, and every handle_event clause
    # is reachable by an arbitrary client frame.
    assert render_click(view, "save", %{"bug_report" => "not-a-map"})
    assert render_click(view, "validate", %{"bug_report" => ["also", "wrong"]})
    assert render_click(view, "no-such-event", %{})

    assert Feedback.list_bug_reports() == []
  end

  describe "the global ceiling" do
    setup do
      original = Application.get_env(:eft_buddy, :max_bug_reports_per_minute)
      Application.put_env(:eft_buddy, :max_bug_reports_per_minute, 2)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:eft_buddy, :max_bug_reports_per_minute)
          value -> Application.put_env(:eft_buddy, :max_bug_reports_per_minute, value)
        end
      end)

      # A fresh window, so a previous test's admissions do not leak into this one.
      Feedback.init_rate_limiter()
      :ok
    end

    test "admits up to the ceiling and then refuses" do
      now = System.system_time(:second)

      assert Feedback.admit(now) == :ok
      assert Feedback.admit(now) == :ok
      assert Feedback.admit(now) == {:error, :rate_limited}
    end

    test "the window rolls" do
      now = System.system_time(:second)

      assert Feedback.admit(now) == :ok
      assert Feedback.admit(now) == :ok
      assert Feedback.admit(now) == {:error, :rate_limited}

      # One second past the window and the budget is fresh again.
      later = now + Feedback.window_seconds() + 1
      assert Feedback.admit(later) == :ok
    end
  end
end
