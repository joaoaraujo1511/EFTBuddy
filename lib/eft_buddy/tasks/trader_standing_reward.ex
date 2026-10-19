defmodule EftBuddy.Tasks.TraderStandingReward do
  @moduledoc """
  Reputation gained / lost with a trader from finishing a task.
  Standings are fractional (e.g. +0.02), so we use `:float`.
  """

  use Ecto.Schema

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
end
