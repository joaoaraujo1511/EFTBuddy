defmodule EftBuddy.Tasks.ItemReward do
  @moduledoc """
  Items granted by a task. `reward_phase` distinguishes items given
  on accept (`:start`, e.g. the Makarov from Debut) from items given
  on turn-in (`:finish`).

  Uses `quantity` for consistency with `EftBuddy.Hideout.ItemRequirement`.
  """

  use Ecto.Schema
  import Ecto.Changeset

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

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:quantity, :reward_phase, :task_id, :item_id])
    |> validate_required([:quantity, :reward_phase, :task_id, :item_id])
    |> validate_number(:quantity, greater_than: 0)
    |> unique_constraint([:task_id, :item_id, :reward_phase],
      name: :task_item_rewards_task_item_phase_index
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:item_id)
  end

  def reward_phases, do: @reward_phases
end
