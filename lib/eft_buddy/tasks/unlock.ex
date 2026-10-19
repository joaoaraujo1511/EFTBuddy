defmodule EftBuddy.Tasks.Unlock do
  @moduledoc """
  Computed reverse index of "complete this task → unlocks this other
  task". Built at the end of every sync from `TaskRequirement` rows
  whose `status` includes `"complete"`, so the quest-chain UI can
  resolve a task's downstream / upstream tasks with a single FK lookup.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_unlocks" do
    belongs_to :prerequisite_task, EftBuddy.Tasks.Task, foreign_key: :prerequisite_task_id
    belongs_to :unlocked_task, EftBuddy.Tasks.Task, foreign_key: :unlocked_task_id

    timestamps()
  end
end
