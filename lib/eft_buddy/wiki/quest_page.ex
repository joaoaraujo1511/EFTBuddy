defmodule EftBuddy.Wiki.QuestPage do
  @moduledoc """
  A scraped wiki walkthrough for one quest, persisted in `wiki_quests`.

  Populated by `EftBuddy.Wiki.Sync` from the EFT Fandom wiki. Cheap
  list-view fields are columns; the full scraped manifest (sections +
  raw wikitext) is the `content` JSONB blob, projected into render-ready
  shape on demand by `EftBuddy.Wiki.Projection`.

  Keyed on `normalized_name` (a slug), not the task UUID, so it survives
  a `mix ecto.reset` / re-sync. `task_id` links to the matched API task
  (NULL for wiki-only WIP quests).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "wiki_quests" do
    field :normalized_name, :string
    field :name, :string
    field :wip, :boolean, default: false
    field :given_by, :string
    field :karma_kind, :string
    field :karma_value, :integer

    # Promoted out of `content` so the Tasks list can render a row thumbnail
    # without projecting every wiki page at mount — see `EftBuddy.Wiki.all_quests/0`.
    field :banner_url, :string

    # The wiki revision this manifest was scraped from. `nil` means unknown, and
    # the only safe reading of unknown is "scrape it" — see `EftBuddy.Wiki.Sync`.
    field :revision_id, :integer

    field :content, :map, default: %{}

    belongs_to :task, EftBuddy.Tasks.Task

    timestamps()
  end

  @fields [
    :normalized_name,
    :name,
    :task_id,
    :wip,
    :given_by,
    :karma_kind,
    :karma_value,
    :banner_url,
    :revision_id,
    :content
  ]

  def changeset(page, attrs) do
    page
    |> cast(attrs, @fields)
    |> validate_required([:normalized_name, :name])
    |> unique_constraint(:normalized_name)
    |> foreign_key_constraint(:task_id)
  end
end
