defmodule EftBuddy.Repo.Migrations.CreateBugReports do
  use Ecto.Migration

  @moduledoc """
  Stores feedback submitted through the in-site "Report a Bug" form
  (`EftBuddyWeb.ReportBugLive`).

    * `reporter_name` — optional display name; NULL for anonymous reports.
    * `title` — required short summary.
    * `description` — required detailed report (free text).
  """

  def change do
    create table(:bug_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reporter_name, :string
      add :title, :string, null: false
      add :description, :text, null: false

      timestamps()
    end
  end
end
