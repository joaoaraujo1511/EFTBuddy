defmodule EftBuddy.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :string, null: false
      add :name, :string, null: false
      add :normalized_name, :string, null: false

      add :wiki_link, :string
      add :task_image_link, :string
      add :faction_name, :string

      add :experience, :integer
      add :min_player_level, :integer

      add :kappa_required, :boolean, null: false, default: false
      add :lightkeeper_required, :boolean, null: false, default: false
      add :restartable, :boolean, null: false, default: false

      add :trader_id,
          references(:traders, type: :binary_id, on_delete: :nilify_all),
          null: true

      # `map` is the task's primary map (per the API). May be null —
      # multi-map tasks express their per-objective maps via the join
      # table `task_objective_maps`.
      add :map_id,
          references(:maps, type: :binary_id, on_delete: :nilify_all),
          null: true

      timestamps()
    end

    create unique_index(:tasks, [:external_id])
    create unique_index(:tasks, [:normalized_name])
    create index(:tasks, [:trader_id])
    create index(:tasks, [:map_id])
    create index(:tasks, [:kappa_required])
    create index(:tasks, [:lightkeeper_required])
  end
end
