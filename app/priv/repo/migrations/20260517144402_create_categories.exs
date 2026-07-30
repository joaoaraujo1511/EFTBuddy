defmodule EftBuddy.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :string
      add :name, :string, null: false
      add :normalized_name, :string
      add :image_link, :string
      add :min_level_for_flea_market, :integer

      timestamps()
    end

    create unique_index(:categories, [:external_id])
  end
end
