defmodule EftBuddy.Repo.Migrations.CreateMapStationaryWeaponsAndSwitches do
  use Ecto.Migration

  def change do
    # Mounted stationary weapons (positioned). One row per emplacement;
    # `name` is resolved from tarkov.dev's stationary-weapon index.
    create table(:map_stationary_weapons, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string
      add :normalized_name, :string

      add :pos_x, :float
      add :pos_y, :float
      add :pos_z, :float

      timestamps()
    end

    create index(:map_stationary_weapons, [:map_id])

    # Interactable switches / levers (extract levers, power switches, …).
    create table(:map_switches, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :map_id,
          references(:maps, type: :binary_id, on_delete: :delete_all),
          null: false

      add :external_id, :string
      add :switch_type, :string

      add :pos_x, :float
      add :pos_y, :float
      add :pos_z, :float

      timestamps()
    end

    create index(:map_switches, [:map_id])
  end
end
