defmodule EftBuddy.Repo.Migrations.DropReporterNameFromBugReports do
  use Ecto.Migration

  @moduledoc """
  Drops `bug_reports.reporter_name`.

  The column was an optional free-text "callsign", and the form's own
  placeholder — "How should we credit you? Leave blank to stay anonymous." —
  actively solicited a real identifier. `bug_reports` is also the only table in
  the application that is not re-derivable from tarkov.dev or the wiki, so it
  was simultaneously the one place a personal identifier could land and the one
  place losing data actually matters.

  EFT-Buddy has no accounts and collects no personal data by design. Storing a
  self-supplied name was the single exception, and it bought nothing: there is
  no reply path, so a name could never be used to answer a reporter.

  Removing the column rather than merely hiding the field is deliberate — a
  nullable column that nothing writes is an invitation for someone to wire a
  form back up to it later.

  Note this gets the product to "we never ask for or store identity", NOT to
  "no personal data at all": `description` is still 5,000 characters of free
  text a reporter may put an address into. `/privacy` says so plainly rather
  than overclaiming.

  Reversible: `down` restores a nullable column. Any values it held are gone,
  which is the point.
  """

  def up do
    alter table(:bug_reports) do
      remove :reporter_name
    end
  end

  def down do
    alter table(:bug_reports) do
      add :reporter_name, :string
    end
  end
end
