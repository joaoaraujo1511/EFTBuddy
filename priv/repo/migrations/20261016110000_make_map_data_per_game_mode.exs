defmodule EftBuddy.Repo.Migrations.MakeMapDataPerGameMode do
  @moduledoc """
  Map data per game mode (audit M13).

  tarkov.dev publishes a maps document per mode, and PVE differs: boss spawn
  chances on 16 of 17 maps (Reshala 60% PVP, 75% PVE), PMC bots in the enemy
  lists, extracts and spawns on five maps, Terminal's access keys, and The Lab
  (dark)'s raid length. Only the PVP document was synced, so PVE players saw
  PVP numbers presented as theirs.

  A map's identity and imagery stay one row in `maps`. Everything upstream
  publishes per mode becomes per mode:

    * every map sub-table gets a `game_mode`, and its unique indexes include it;
    * the per-mode map attributes (enemies, raid duration, players, level
      limits) move to `map_mode_details`, one row per map per mode.

  Existing rows came from the PVP document, so they backfill as "regular"; the
  next MapsSync writes PVE.
  """
  use Ecto.Migration

  @sub_tables ~w(map_variants map_bosses map_extracts map_transits map_locks map_hazards
                 map_spawns map_loot_containers map_stationary_weapons map_switches
                 map_access_keys)a

  @unique_indexes [
    {:map_variants, [:map_id, :normalized_name]},
    {:map_extracts, [:map_id, :external_id]},
    {:map_transits, [:map_id, :external_id]},
    {:map_hazards, [:map_id, :hazard_type, :name]},
    {:map_access_keys, [:map_id, :item_id]}
  ]

  @mode_columns [
    {:enemies, {:array, :string}, default: []},
    {:raid_duration, :integer, []},
    {:players, :string, []},
    {:min_player_level, :integer, []},
    {:max_player_level, :integer, []},
    {:access_keys_min_player_level, :integer, []}
  ]

  def up do
    for table <- @sub_tables do
      alter table(table) do
        add :game_mode, :string, null: false, default: "regular"
      end

      create index(table, [:map_id, :game_mode])
    end

    for {table, columns} <- @unique_indexes do
      drop unique_index(table, columns)
      create unique_index(table, columns ++ [:game_mode])
    end

    create table(:map_mode_details, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :map_id, references(:maps, type: :binary_id, on_delete: :delete_all), null: false
      add :game_mode, :string, null: false

      for {name, type, opts} <- @mode_columns, do: add(name, type, opts)

      timestamps()
    end

    create unique_index(:map_mode_details, [:map_id, :game_mode])

    execute """
    INSERT INTO map_mode_details
      (id, map_id, game_mode, enemies, raid_duration, players, min_player_level,
       max_player_level, access_keys_min_player_level, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, 'regular', coalesce(enemies, '{}'), raid_duration, players,
           min_player_level, max_player_level, access_keys_min_player_level,
           inserted_at, updated_at
    FROM maps
    """

    alter table(:maps) do
      for {name, _type, _opts} <- @mode_columns, do: remove(name)
    end
  end

  def down do
    alter table(:maps) do
      for {name, type, opts} <- @mode_columns, do: add(name, type, opts)
    end

    execute """
    UPDATE maps m
    SET enemies = d.enemies, raid_duration = d.raid_duration, players = d.players,
        min_player_level = d.min_player_level, max_player_level = d.max_player_level,
        access_keys_min_player_level = d.access_keys_min_player_level
    FROM map_mode_details d
    WHERE d.map_id = m.id AND d.game_mode = 'regular'
    """

    drop table(:map_mode_details)

    # Rolling back to one dataset keeps the PVP rows.
    for table <- @sub_tables do
      execute "DELETE FROM #{table} WHERE game_mode <> 'regular'"
    end

    for {table, columns} <- @unique_indexes do
      drop unique_index(table, columns ++ [:game_mode])
      create unique_index(table, columns)
    end

    for table <- @sub_tables do
      drop index(table, [:map_id, :game_mode])

      alter table(table) do
        remove :game_mode
      end
    end
  end
end
