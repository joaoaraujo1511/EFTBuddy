defmodule EftBuddy.Repo.Migrations.CreateItemsCraftRequiredItems do
  use Ecto.Migration

  def change do
    create table(:items_craft_required_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:count, :integer, null: false)
      add(:quantity, :integer, null: false)
      add(:attributes, :map, default: %{})

      add(:craft_id, references(:items_crafts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:item_id, references(:items, type: :binary_id, on_delete: :restrict), null: false)

      timestamps()
    end

    create(index(:items_craft_required_items, [:craft_id]))
    create(index(:items_craft_required_items, [:item_id]))
  end
end
