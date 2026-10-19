defmodule EftBuddy.Items.Barter do
  @moduledoc """
  A trader barter recipe: pay `required_items` at `trader` (level
  `level`) to receive `reward_items`. Optionally gated by completion
  of a task via `task_unlock`.

  Stored under the Items context because barters are primarily a
  way to *acquire an item* — they show up on the expanded item card
  alongside crafts and task rewards.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "items_barters" do
    field :external_id, :string
    field :level, :integer
    field :buy_limit, :integer
    field :game_mode, :string, default: "regular"

    belongs_to :trader, EftBuddy.Hideout.Trader
    belongs_to :task_unlock, EftBuddy.Tasks.Task

    has_many :required_items, EftBuddy.Items.BarterRequiredItem,
      foreign_key: :barter_id,
      on_replace: :delete

    has_many :reward_items, EftBuddy.Items.BarterRewardItem,
      foreign_key: :barter_id,
      on_replace: :delete

    timestamps()
  end
end
