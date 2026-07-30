defmodule EftBuddy.Repo.Migrations.AddImageLinkToTraders do
  use Ecto.Migration

  def change do
    alter table(:traders) do
      add :image_link, :string
    end
  end
end
