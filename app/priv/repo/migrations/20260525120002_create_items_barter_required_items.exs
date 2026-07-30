defmodule EftBuddy.Repo.Migrations.CreateItemsBarterRequiredItems do
  use Ecto.Migration

  def change do
    create table(:items_barter_required_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      # The Tarkov.dev API surfaces both `count` (stack size) and
      # `quantity` (number of stacks). For barters they're almost
      # always equal, but we store both verbatim so the UI can
      # display "2x M67 (5 each)" if the API ever distinguishes
      # them. We index the simpler `quantity` field for "how many
      # of item X does this barter consume" lookups.
      add(:count, :integer, null: false)
      add(:quantity, :integer, null: false)

      # Free-form attribute payload (e.g. dogtag minLevel). Rare,
      # but JSON keeps the schema flat — ~5 known attributes total
      # in the live API at the time of writing.
      add(:attributes, :map, default: %{})

      add(:barter_id, references(:items_barters, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:item_id, references(:items, type: :binary_id, on_delete: :restrict), null: false)

      timestamps()
    end

    # A barter can list the same item twice with different
    # attributes (e.g. two dogtag slots at different min levels), so
    # the unique index includes the JSON column. Postgres allows
    # jsonb in expression indexes, but we keep things simple by just
    # not constraining uniqueness — the API row is the source of
    # truth and we resync the whole set.
    create(index(:items_barter_required_items, [:barter_id]))
    create(index(:items_barter_required_items, [:item_id]))
  end
end
