defmodule EftBuddy.Tasks.ItemReward do
  @moduledoc """
  Items granted by a task. `reward_phase` distinguishes items given
  on accept (`:start`, e.g. the Makarov from Debut) from items given
  on turn-in (`:finish`).

  Uses `quantity` for consistency with `EftBuddy.Hideout.ItemRequirement`.
  """

  use Ecto.Schema

  @reward_phases ~w(start finish)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_item_rewards" do
    field :quantity, :integer
    field :reward_phase, Ecto.Enum, values: @reward_phases

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end

  def reward_phases, do: @reward_phases
end
