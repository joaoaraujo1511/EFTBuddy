defmodule EftBuddy.Repo.Migrations.RelaxBarterCraftItemFkToDeleteAll do
  use Ecto.Migration

  # The barter/craft child tables referenced `items` with
  # `on_delete: :restrict`, but `Items.Sync.cleanup_stale/2` deletes items that
  # drop out of the API snapshot *before* the barter/craft sub-sync prunes the
  # rows that reference them. A stale item still referenced by a barter/craft
  # made that delete raise an FK violation and rolled back the entire items
  # sync, so it never recovered on subsequent ticks.
  #
  # Switch these FKs to `:delete_all` so a removed item takes its now-orphaned
  # barter/craft child rows with it. This matches `task_item_rewards` and
  # `hideout_item_requirements`, which already use `:delete_all` on `item_id`.
  # The parent barter/craft is re-evaluated (and dropped if it has become
  # unresolvable) by the barter/craft sync that runs immediately afterwards.
  @tables [
    :items_barter_required_items,
    :items_barter_reward_items,
    :items_craft_required_items,
    :items_craft_reward_items
  ]

  def up do
    for table <- @tables do
      alter table(table) do
        modify(:item_id, references(:items, type: :binary_id, on_delete: :delete_all),
          from: references(:items, type: :binary_id, on_delete: :restrict),
          null: false
        )
      end
    end
  end

  def down do
    for table <- @tables do
      alter table(table) do
        modify(:item_id, references(:items, type: :binary_id, on_delete: :restrict),
          from: references(:items, type: :binary_id, on_delete: :delete_all),
          null: false
        )
      end
    end
  end
end
