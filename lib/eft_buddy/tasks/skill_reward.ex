defmodule EftBuddy.Tasks.SkillReward do
  @moduledoc """
  XP toward a character skill granted by a task. Float to match the
  API (e.g. +0.5 to Endurance).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @reward_phases ~w(start finish)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_skill_rewards" do
    field :level, :float
    field :reward_phase, Ecto.Enum, values: @reward_phases

    belongs_to :task, EftBuddy.Tasks.Task
    belongs_to :skill, EftBuddy.Hideout.Skill

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:level, :reward_phase, :task_id, :skill_id])
    |> validate_required([:level, :reward_phase, :task_id, :skill_id])
    |> unique_constraint([:task_id, :skill_id, :reward_phase],
      name: :task_skill_rewards_task_skill_phase_index
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:skill_id)
  end
end
