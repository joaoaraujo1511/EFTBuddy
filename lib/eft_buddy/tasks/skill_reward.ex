defmodule EftBuddy.Tasks.SkillReward do
  @moduledoc """
  XP toward a character skill granted by a task. Float to match the
  API (e.g. +0.5 to Endurance).
  """

  use Ecto.Schema

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
end
