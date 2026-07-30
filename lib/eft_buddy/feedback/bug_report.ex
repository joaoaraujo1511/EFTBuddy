defmodule EftBuddy.Feedback.BugReport do
  @moduledoc """
  A user-submitted bug report, captured from the in-site "Report a Bug"
  form (see `EftBuddyWeb.ReportBugLive`) and persisted in `bug_reports`.

  Fields:

    * `title` — required, short summary of the problem.
    * `description` — required, the detailed report.

  ## No identity field, deliberately

  There was a `reporter_name` column. It is gone (migration
  `20260730120000`). EFT-Buddy has no accounts and collects no personal data,
  and an optional "how should we credit you?" field was the one place that
  claim broke — while buying nothing, since there is no reply path back to a
  reporter. This is also the only table in the app that is not re-derivable
  from tarkov.dev or the wiki, so it is the worst place for an identifier to
  accumulate.

  That gets us to "we never ask for or store identity", not to "no personal
  data at all": `description` is free text and a reporter can still type an
  address into it. `/privacy` states the accurate version.

  ## Reading them

  There is no in-app triage page, deliberately. One existed briefly at
  `/dev/reports` behind basic auth; it was removed rather than ship an
  authenticated admin surface on the public internet for a single operator.

  Read the table through the database host's own console, which gives real
  accounts, 2FA and an audit trail — none of which a shared password does — or
  from IEx via `EftBuddy.Feedback.list_bug_reports/1`. That is also where row
  deletion lives, which is what answers an erasure request.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "bug_reports" do
    field :title, :string
    field :description, :string

    timestamps()
  end

  @title_max 150
  @description_max 5000

  @doc """
  Build a changeset for a bug report.

  Both fields are required. Leading/trailing whitespace is trimmed so a field
  of only spaces reads as blank and therefore fails the required check.
  """
  def changeset(bug_report, attrs) do
    bug_report
    |> cast(attrs, [:title, :description])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> validate_required([:title, :description])
    |> validate_length(:title, max: @title_max)
    |> validate_length(:description, min: 10, max: @description_max)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
