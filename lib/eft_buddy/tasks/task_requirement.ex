defmodule EftBuddy.Tasks.TaskRequirement do
  @moduledoc """
  "To start task X you must have task Y in some status (complete,
  active, failed, …)." Status is an array because the API returns it
  as a list.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_task_requirements" do
    field :status, {:array, :string}, default: []

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :prerequisite_task, EftBuddy.Tasks.Task, foreign_key: :prerequisite_task_id

    timestamps()
  end

  def changeset(req, attrs) do
    req
    |> cast(attrs, [:status, :task_id, :prerequisite_task_id])
    |> validate_required([:task_id, :prerequisite_task_id])
    |> unique_constraint([:task_id, :prerequisite_task_id],
      name: :task_task_reqs_task_prereq_index
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:prerequisite_task_id)
  end
end
