defmodule EftBuddy.Repo.Migrations.AddDescriptionToItems do
  use Ecto.Migration

  def change do
    alter table(:items) do
      add(:description, :text)
    end
  end
end
