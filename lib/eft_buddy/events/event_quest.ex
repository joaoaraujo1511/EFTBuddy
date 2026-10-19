defmodule EftBuddy.Events.EventQuest do
  @moduledoc """
  A quest introduced by an event, persisted in `event_quests`.

  Populated by `EftBuddy.Events.Sync`: every quest the "Events" page
  reports as added by an event (`Quest [[Name]] has been added.`) gets
  its own wiki page scraped through the SAME pipeline as a regular quest
  (`EftBuddy.Wiki.Dump`), so `content` holds the identical manifest
  shape `wiki_quests.content` does. `EftBuddy.Wiki.Projection` therefore
  renders an event quest's objectives/guide exactly like the Tasks tab.

  The ones tarkov.dev does not serve as tasks are blacklisted from
  `EftBuddy.Wiki.Sync`, so they do not surface as WIP on the Tasks tab; this
  table is the source of truth for that blacklist. Those that ARE real tasks
  keep their wiki guide on the Tasks tab as well.

  Keyed by `(event_id, normalized_name)` — a quest added by two
  different events gets a row under each. `task_id` is a best-effort FK
  to a tarkov.dev task and is almost always NULL (event quests are
  wiki-only).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "event_quests" do
    field :normalized_name, :string
    field :name, :string
    field :position, :integer, default: 0
    field :content, :map, default: %{}
    # The wiki revision `content` was scraped at, so unchanged pages are not
    # fetched again. NULL means "scrape it": never scraped, or scraped with a
    # section, image or roster missing.
    field :revision_id, :integer

    belongs_to :event, EftBuddy.Events.Event
    belongs_to :task, EftBuddy.Tasks.Task

    timestamps()
  end

  @fields [:event_id, :normalized_name, :name, :task_id, :position, :content, :revision_id]

  def changeset(quest, attrs) do
    quest
    |> cast(attrs, @fields)
    |> validate_required([:event_id, :normalized_name, :name])
    |> unique_constraint([:event_id, :normalized_name],
      name: :event_quests_event_id_normalized_name_index
    )
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:task_id)
  end
end
