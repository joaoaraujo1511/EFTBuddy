defmodule EftBuddy.Repo.Migrations.RelaxBarterTraderCraftStationFkToDeleteAll do
  use Ecto.Migration

  # Follow-up to 20260612120000, which relaxed the barter/craft *item*
  # FKs to `:delete_all`. Two parent-side FKs were left on `:restrict`
  # and re-expose the exact same failure class:
  #
  #   * `items_barters.trader_id`        → `traders`
  #   * `items_crafts.station_level_id`  → `hideout_station_levels`
  #
  # A sync that prunes a trader or a hideout station level (because it
  # dropped out of the upstream API snapshot) while a barter/craft still
  # references it would raise an FK violation under `:restrict` and roll
  # back the whole run, never recovering on later ticks. Both columns are
  # `null: false`, so `:nilify_all` isn't an option — switch them to
  # `:delete_all` so a removed parent takes its now-meaningless
  # barter/craft rows with it. The barter/craft sync that runs right
  # afterwards re-creates whatever is still resolvable. This matches the
  # resilience strategy already used everywhere else (task_*, hideout_*,
  # and the barter/craft item FKs).

  def up do
    alter table(:items_barters) do
      modify(:trader_id, references(:traders, type: :binary_id, on_delete: :delete_all),
        from: references(:traders, type: :binary_id, on_delete: :restrict),
        null: false
      )
    end

    alter table(:items_crafts) do
      modify(
        :station_level_id,
        references(:hideout_station_levels, type: :binary_id, on_delete: :delete_all),
        from: references(:hideout_station_levels, type: :binary_id, on_delete: :restrict),
        null: false
      )
    end
  end

  def down do
    alter table(:items_barters) do
      modify(:trader_id, references(:traders, type: :binary_id, on_delete: :restrict),
        from: references(:traders, type: :binary_id, on_delete: :delete_all),
        null: false
      )
    end

    alter table(:items_crafts) do
      modify(
        :station_level_id,
        references(:hideout_station_levels, type: :binary_id, on_delete: :restrict),
        from: references(:hideout_station_levels, type: :binary_id, on_delete: :delete_all),
        null: false
      )
    end
  end
end
