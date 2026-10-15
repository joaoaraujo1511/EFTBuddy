defmodule EftBuddy.Repo.Migrations.AllowUnresolvedCraftIngredients do
  @moduledoc """
  A craft ingredient may name an item tarkov.dev doesn't define yet.

  Upstream can list a quest item as an ingredient before it lists the item
  itself (Intelligence Center's "Data from Fence's laptop" craft, October
  2026). Such an ingredient is stored with no `item_id` and the upstream id in
  `unresolved_external_id`, and the page shows it as an unknown quest item, so
  the recipe appears and is visibly incomplete rather than hidden or shown as
  complete. Every row names one or the other.
  """
  use Ecto.Migration

  def change do
    alter table(:items_craft_required_items) do
      modify :item_id, :binary_id, null: true, from: {:binary_id, null: false}
      add :unresolved_external_id, :string
    end

    create constraint(:items_craft_required_items, :item_or_unresolved_external_id,
             check: "item_id IS NOT NULL OR unresolved_external_id IS NOT NULL"
           )
  end
end
