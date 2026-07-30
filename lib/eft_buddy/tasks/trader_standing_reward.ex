defmodule EftBuddy.Tasks.TraderStandingReward do
  @moduledoc """
  Reputation gained / lost with a trader from finishing a task.
  Standings are fractional (e.g. +0.02), so we use `:float`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @reward_phases ~w(start finish)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_trader_standing_rewards" do
    field :standing, :float
    field :reward_phase, Ecto.Enum, values: @reward_phases

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :trader, EftBuddy.Hideout.Trader

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:standing, :reward_phase, :task_id, :trader_id])
    |> validate_required([:standing, :reward_phase, :task_id, :trader_id])
    |> unique_constraint([:task_id, :trader_id, :reward_phase],
      name: :task_trader_standing_rewards_task_trader_phase_index
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:trader_id)
  end
end
