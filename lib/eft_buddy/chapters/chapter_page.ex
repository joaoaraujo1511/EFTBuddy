defmodule EftBuddy.Chapters.ChapterPage do
  @moduledoc """
  A scraped wiki storyline chapter (or the "Endings" reference page),
  persisted in `wiki_chapters`.

  Populated by `EftBuddy.Chapters.Sync` from the EFT Fandom wiki. The
  cleaned display title is a column (`chapter_name`); the full scraped
  manifest (sections + raw wikitext + resolved image urls) is the
  `content` JSONB blob, projected into render-ready shape on demand by
  `EftBuddy.Chapters.Projection`.

  Storyline counterpart to `EftBuddy.Wiki.QuestPage`. Unlike a quest,
  a chapter has no tarkov.dev task behind it, so there is no `task_id` /
  `wip` — chapters are always wiki-only. Keyed on `normalized_name` (a
  slug, e.g. "boreas") so it survives a `mix ecto.reset` / re-sync.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "wiki_chapters" do
    field :normalized_name, :string
    field :chapter_name, :string
    field :content, :map, default: %{}

    timestamps()
  end

  @fields [:normalized_name, :chapter_name, :content]

  def changeset(page, attrs) do
    page
    |> cast(attrs, @fields)
    |> validate_required([:normalized_name, :chapter_name])
    |> unique_constraint(:normalized_name)
  end
end
