defmodule EftBuddy.Wiki.BlacklistedPage do
  @moduledoc """
  A quest page the scrape skips (a Ref quest or `{{Historical content}}`), with
  the revision it was judged at. Written and read only by `EftBuddy.Wiki.Sync`,
  which skips the page while its revision is unchanged.
  """
  use Ecto.Schema

  schema "wiki_blacklisted_pages" do
    field :wiki_title, :string
    field :revision_id, :integer
    field :reason, :string

    timestamps()
  end
end
