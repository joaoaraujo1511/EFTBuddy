defmodule EftBuddy.Tasks.TaskRequirement do
  @moduledoc """
  "To start task X you must have task Y in some status (complete,
  active, failed, …)." Status is an array because the API returns it
  as a list.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_task_requirements" do
    field :status, {:array, :string}, default: []

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :prerequisite_task, EftBuddy.Tasks.Task, foreign_key: :prerequisite_task_id

    timestamps()
  end
end
