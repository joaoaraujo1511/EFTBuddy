defmodule EftBuddy.Repo.Migrations.AddContainsItemIdToItems do
  @moduledoc """
  Add a self-referential `contains_item_id` FK to items so we can
  track ammo-box → ammo-round relationships (and any future
  single-content container we want to dedupe against).

  The motivating case: tarkov.dev's `barters` API returns barter
  rewards at both the ammo-box level (e.g. "Pack of .300 Blackout
  CBJ ammo") and at the round level (".300 Blackout CBJ"). Both
  end up in `items_barter_reward_items`, so the BARTER ITEMS
  scope on the Items tab listed the same conceptual barter twice.
  Storing the box → round relationship lets the scope query
  exclude the contained round when its container also has a
  barter row.

  Populated by `EftBuddy.Items.Sync.set_contains_item_id/3` from
  the `properties { ... on ItemPropertiesAmmoBox { ammo { id } } }`
  fragment on the items query. `nil` for everything else
  (which is the vast majority of items).

  `:nilify_all` on delete because if the contained round ever
  disappears from the API snapshot, the box should keep existing
  with a null pointer rather than cascading away.
  """

  use Ecto.Migration

  def change do
    alter table(:items) do
      add(:contains_item_id, references(:items, type: :binary_id, on_delete: :nilify_all))
    end

    # The scope-time dedupe query joins on `contains_item_id`, so an
    # index keeps that filter cheap as the items table grows.
    create(index(:items, [:contains_item_id]))
  end
end
