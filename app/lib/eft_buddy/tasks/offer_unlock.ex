defmodule EftBuddy.Tasks.OfferUnlock do
  @moduledoc """
  A task that unlocks a specific trader offer — i.e. trader X starts
  selling item Y at loyalty level Z.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @reward_phases ~w(start finish)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_offer_unlocks" do
    field :level, :integer
    field :reward_phase, Ecto.Enum, values: @reward_phases

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :trader, EftBuddy.Hideout.Trader
    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:level, :reward_phase, :task_id, :trader_id, :item_id])
    |> validate_required([:level, :reward_phase, :task_id, :trader_id, :item_id])
    |> validate_number(:level, greater_than_or_equal_to: 1)
    |> unique_constraint([:task_id, :trader_id, :item_id, :reward_phase],
      name: :task_offer_unlocks_task_trader_item_phase_index
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:trader_id)
    |> foreign_key_constraint(:item_id)
  end
end
