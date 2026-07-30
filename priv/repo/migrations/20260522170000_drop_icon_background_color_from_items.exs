defmodule EftBuddy.Repo.Migrations.DropIconBackgroundColorFromItems do
  use Ecto.Migration

  # Rolls back 20260522120000_add_icon_background_color_to_items.exs.
  # The icon-color sampling approach didn't pan out and has been
  # removed; the Items tab now just renders image_512px_link directly.
  # Using a new migration (rather than editing the original) so anyone
  # who already migrated can move forward cleanly.
  def change do
    alter table(:items) do
      remove :icon_background_color, :string, size: 7
    end
  end
end
