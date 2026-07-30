defmodule EftBuddy.Items.Craft do
  @moduledoc """
  A hideout craft recipe: combine `required_items` at the given
  `station_level` (e.g. Workbench level 2) and after `duration`
  seconds receive `reward_items`. Optionally gated by completion
  of a task via `task_unlock`.

  Lives in the Items context because crafts are primarily a way to
  *acquire an item* — they show up on the expanded item card
  alongside barters and task rewards. The station/level reference
  is a foreign key into the existing Hideout schema so we don't
  duplicate that data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_crafts" do
    field(:external_id, :string)
    field(:duration, :integer)

    belongs_to(:station_level, EftBuddy.Hideout.StationLevel)
    belongs_to(:task_unlock, EftBuddy.Tasks.Task)

    has_many(:required_items, EftBuddy.Items.CraftRequiredItem,
      foreign_key: :craft_id,
      on_replace: :delete
    )

    has_many(:reward_items, EftBuddy.Items.CraftRewardItem,
      foreign_key: :craft_id,
      on_replace: :delete
    )

    timestamps()
  end

  def changeset(craft, attrs) do
    craft
    |> cast(attrs, [:external_id, :duration, :station_level_id, :task_unlock_id])
    |> validate_required([:external_id, :duration, :station_level_id])
    |> validate_number(:duration, greater_than_or_equal_to: 0)
    |> unique_constraint(:external_id)
    |> foreign_key_constraint(:station_level_id)
    |> foreign_key_constraint(:task_unlock_id)
  end
end
