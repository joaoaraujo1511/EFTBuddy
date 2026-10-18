defmodule EftBuddy.Tasks.TraderUnlock do
  @moduledoc """
  A task whose completion unlocks an entire trader (e.g. Ref via
  Lightkeeper, Lightkeeper itself).
  """

  use Ecto.Schema

  @reward_phases ~w(start finish)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_trader_unlocks" do
    field :reward_phase, Ecto.Enum, values: @reward_phases

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :trader, EftBuddy.Hideout.Trader

    timestamps()
  end
end
