defmodule EftBuddy.Tasks.TraderRequirement do
  @moduledoc """
  Trader-related prerequisite for starting a task — typically
  "Trader X must be at loyalty level >= N" but the API also allows
  comparing standing or other values, so we keep `requirement_type`
  / `compare_method` / `value` verbatim.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_trader_requirements" do
    field :requirement_type, :string
    field :compare_method, :string
    field :value, :integer

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :trader, EftBuddy.Hideout.Trader

    timestamps()
  end

  def changeset(req, attrs) do
    req
    |> cast(attrs, [:requirement_type, :compare_method, :value, :task_id, :trader_id])
    |> validate_required([:task_id, :trader_id])
    |> unique_constraint([:task_id, :trader_id, :requirement_type],
      name: :task_trader_reqs_task_trader_type_index
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:trader_id)
  end
end
