defmodule EftBuddy.Repo.Migrations.AllowFractionalRecipeCounts do
  @moduledoc """
  Barter and craft ingredient counts become `numeric`.

  tarkov.dev reports some as fractions, and shows them that way: Ref prices
  hundreds of barters in fractional GP coins (355.92 for a Medicine case,
  0.42 for the cheapest), and the Water Collector uses 0.66 of a Water filter.
  Stored as integers they were truncated, so a 0.42 GP barter read "x0".
  """
  use Ecto.Migration

  @tables [:items_barter_required_items, :items_craft_required_items]

  def up do
    for table <- @tables do
      alter table(table) do
        modify :count, :decimal, null: false, from: {:integer, null: false}
        modify :quantity, :decimal, null: false, from: {:integer, null: false}
      end
    end
  end

  # Rounds any fraction up, so a rollback never turns a real cost into zero.
  def down do
    for table <- @tables do
      execute "ALTER TABLE #{table} ALTER COLUMN count TYPE integer USING ceil(count)"
      execute "ALTER TABLE #{table} ALTER COLUMN quantity TYPE integer USING ceil(quantity)"
    end
  end
end
