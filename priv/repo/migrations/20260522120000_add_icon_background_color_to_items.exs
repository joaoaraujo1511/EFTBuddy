defmodule EftBuddy.Repo.Migrations.AddIconBackgroundColorToItems do
  use Ecto.Migration

  def change do
    alter table(:items) do
      # Sampled at sync time from the item's icon_link PNG. Stored as
      # a CSS-ready "#rrggbb" string. Nullable so the sync can fill it
      # in lazily (and so a sampling failure doesn't block anything).
      add :icon_background_color, :string, size: 7
    end
  end
end
