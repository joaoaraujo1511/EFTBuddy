defmodule EftBuddy.Tasks.OfferUnlock do
  @moduledoc """
  A task that unlocks a specific trader offer — i.e. trader X starts
  selling item Y at loyalty level Z.
  """

  use Ecto.Schema

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
end
