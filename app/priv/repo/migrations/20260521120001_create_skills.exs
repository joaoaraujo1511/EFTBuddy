defmodule EftBuddy.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :normalized_name, :string, null: false

      timestamps()
    end

    create unique_index(:skills, [:normalized_name])
  end
end
