defmodule EftBuddy.Maps.MapModeDetail do
  @moduledoc """
  The attributes tarkov.dev publishes per game mode for a map: who spawns
  (PVE adds PMC bots), raid length, player count and level limits. One row per
  map per mode; `EftBuddy.Maps` overlays the active mode's row onto the map.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_mode_details" do
    field :game_mode, :string
    field :enemies, {:array, :string}, default: []
    field :raid_duration, :integer
    field :players, :string
    field :min_player_level, :integer
    field :max_player_level, :integer
    field :access_keys_min_player_level, :integer

    belongs_to :map, EftBuddy.Maps.Map

    timestamps()
  end

  @doc "The fields `EftBuddy.Maps` copies onto a `%EftBuddy.Maps.Map{}`."
  def overlay_fields,
    do: [
      :enemies,
      :raid_duration,
      :players,
      :min_player_level,
      :max_player_level,
      :access_keys_min_player_level
    ]
end
