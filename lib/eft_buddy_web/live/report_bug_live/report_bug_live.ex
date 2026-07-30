defmodule EftBuddyWeb.ReportBugLive.Index do
  @moduledoc """
  In-site "Report a Bug" form, reached from the command bar's quick action.

  Collects a title and a description — and nothing else. There is deliberately
  no identity field; see `EftBuddy.Feedback.BugReport`. On a successful submit
  the form is swapped for a confirmation panel with a "Report another"
  affordance.

  Submission is rate limited (see `EftBuddy.Feedback.admit/1`): this is an
  unauthenticated write path into the only table in the app that is not
  re-derivable from an upstream, and a burst of inserts monopolises the same
  ten-connection pool every page shares.
  """
  use EftBuddyWeb, :live_view

  alias EftBuddy.Feedback
  alias EftBuddy.Feedback.BugReport

  # Per-socket half of the rate limit. Long enough that a script gains nothing
  # from holding one connection open, short enough that a person who spots a
  # typo in what they just sent can correct it without feeling punished.
  @cooldown_seconds 60

  @cooldown_message "Thanks - you've just sent a report. Please wait a minute before sending another."
  @busy_message "We're receiving a lot of reports right now. Please try again in a minute."

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Report a Bug")
      |> assign(
        :page_description,
        "Found something broken in EFT Buddy? Report it here so we can fix it."
      )
      |> assign(:active, :report_bug)
      |> assign(:submitted, false)
      # When this socket last submitted, for the per-socket half of the rate
      # limit. Socket assigns are the right home: the limit is per browser
      # connection, and nothing durable should be written for an anonymous
      # visitor just to police them.
      |> assign(:last_report_at, nil)
      |> assign_form(Feedback.change_bug_report())

    {:ok, socket}
  end

  # `is_map/1` on the nested params, and a catch-all below, because every
  # `handle_event/3` clause is reachable by an arbitrary client frame regardless
  # of what the page renders — and `Ecto.Changeset.cast/3` raises on a
  # non-map. A forged event should be a no-op, not a crashed LiveView.
  @impl true
  def handle_event("validate", %{"bug_report" => params}, socket) when is_map(params) do
    changeset =
      %BugReport{}
      |> Feedback.change_bug_report(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"bug_report" => params}, socket) when is_map(params) do
    now = System.system_time(:second)

    cond do
      cooling_down?(socket.assigns.last_report_at, now) ->
        {:noreply, reject(socket, params, @cooldown_message)}

      Feedback.admit(now) == {:error, :rate_limited} ->
        {:noreply, reject(socket, params, @busy_message)}

      true ->
        save(socket, params, now)
    end
  end

  def handle_event("report_another", _params, socket) do
    {:noreply,
     socket
     |> assign(:submitted, false)
     |> assign_form(Feedback.change_bug_report())}
  end

  # Must stay LAST: swallows any event this page does not define, including a
  # `"validate"` / `"save"` whose payload is the wrong shape.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(socket, params, now) do
    case Feedback.create_bug_report(params) do
      {:ok, _bug_report} ->
        {:noreply,
         socket
         |> assign(:submitted, true)
         |> assign(:last_report_at, now)
         |> assign_form(Feedback.change_bug_report())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # A refused submission must not look like a successful one, and must not lose
  # what the reporter typed — so the message goes on the changeset they are
  # already looking at rather than into a flash.
  defp reject(socket, params, message) do
    changeset =
      %BugReport{}
      |> Feedback.change_bug_report(params)
      |> Ecto.Changeset.add_error(:description, message)
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end

  defp cooling_down?(nil, _now), do: false
  defp cooling_down?(last_at, now), do: now - last_at < @cooldown_seconds

  # HUD pings / client-restore blob aren't consumed here.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :bug_report))
  end
end
