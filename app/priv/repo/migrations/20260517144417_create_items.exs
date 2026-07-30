defmodule EftBuddy.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :string
      add :name, :string, null: false
      add :short_name, :string
      add :normalized_name, :string
      add :base_price, :integer
      add :last_low_price, :integer
      add :avg_24h_price, :integer
      add :low_24h_price, :integer
      add :high_24h_price, :integer
      add :change_last_48h, :float
      add :change_last_48h_percent, :float
      add :wiki_link, :string
      add :link, :string
      add :icon_link, :string
      add :grid_image_link, :string
      add :base_image_link, :string
      add :inspect_image_link, :string
      add :image_512px_link, :string
      add :image_8x_link, :string
      add :category_id, references(:categories, type: :binary_id)

      timestamps()
    end

    create unique_index(:items, [:external_id])
  end
end
