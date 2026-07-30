defmodule EftBuddy.Repo.Migrations.CreateTaskSkillRewards do
  use Ecto.Migration

  def change do
    create table(:task_skill_rewards, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :skill_id,
          references(:skills, type: :binary_id, on_delete: :delete_all),
          null: false

      # API returns a fractional level reward.
      add :level, :float, null: false
      add :reward_phase, :string, null: false

      timestamps()
    end

    create index(:task_skill_rewards, [:task_id])
    create index(:task_skill_rewards, [:skill_id])

    create unique_index(:task_skill_rewards, [:task_id, :skill_id, :reward_phase],
             name: :task_skill_rewards_task_skill_phase_index
           )
  end
end
