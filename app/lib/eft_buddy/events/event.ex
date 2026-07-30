defmodule EftBuddy.Events.Event do
  @moduledoc """
  A limited-time in-game event scraped from the EFT Fandom "Events"
  page, persisted in `events`.

  Populated by `EftBuddy.Events.Sync`. Cheap list-view fields (name,
  date, status, banner) are columns; the full scraped detail — the
  gameplay-changes list, banner metadata, availability note and the raw
  quest refs — is the `content` JSONB blob.

  Keyed on `normalized_name` (a slug derived from the full `Name (date)`
  heading, e.g. `"bonus-xp-weekend-12-june-2026"`) so recurring events
  stay distinct and the key survives a `mix ecto.reset` / re-sync.

  Events counterpart to `EftBuddy.Wiki.QuestPage` / `EftBuddy.Chapters.ChapterPage`.
  The quests an event introduces live in `event_quests` (the
  `has_many :quests` association); each carries its own scraped
  walkthrough so the Events tab can render objectives/guide via
  `EftBuddy.Wiki.Projection`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "events" do
    field :normalized_name, :string
    field :name, :string
    field :event_date, :string
    field :started_on, :date
    field :status, :string, default: "past"
    field :position, :integer, default: 0
    field :banner_url, :string
    field :description, :string
    field :content, :map, default: %{}

    has_many :quests, EftBuddy.Events.EventQuest,
      foreign_key: :event_id,
      preload_order: [asc: :position]

    timestamps()
  end

  @fields [
    :normalized_name,
    :name,
    :event_date,
    :started_on,
    :status,
    :position,
    :banner_url,
    :description,
    :content
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:normalized_name, :name])
    |> validate_inclusion(:status, ["active", "past"])
    |> unique_constraint(:normalized_name)
  end
end
