defmodule EftBuddy.Repo.Migrations.AddOnDeleteToPriceItemFks do
  use Ecto.Migration

  @moduledoc """
  Make the `sell_for.item_id` / `buy_for.item_id` foreign keys
  `on_delete: :delete_all`.

  They were created with no `:on_delete` (Postgres default `NO ACTION`).
  Today `Items.Sync.cleanup_stale/2` manually deletes a stale item's
  price rows before deleting the item, so the constraint never fires —
  but that couples the price tables to the exact delete-ordering in one
  function. Any other code path that deletes an item (a future admin
  action, a manual fix-up in IEx, a test) would hit a FK violation.

  Switching to `:delete_all` matches the intent — a price row is
  meaningless without its item — and mirrors the `:delete_all` already
  used on `hideout_item_requirements.item_id`, `task_item_rewards.item_id`
  and the barter/craft item FKs.
  """

  @tables [:sell_for, :buy_for]

  def up do
    for table <- @tables do
      drop(constraint(table, "#{table}_item_id_fkey"))

      alter table(table) do
        modify(:item_id, references(:items, type: :binary_id, on_delete: :delete_all))
      end
    end
  end

  def down do
    for table <- @tables do
      drop(constraint(table, "#{table}_item_id_fkey"))

      alter table(table) do
        modify(:item_id, references(:items, type: :binary_id))
      end
    end
  end
end
