defmodule EftBuddy.Maps.AccessKey do
  @moduledoc """
  Join row: a key item required to access a map (tarkov.dev
  `Map.accessKeys`). `item` is the link target for the Items tab; the
  PMC-level gate lives on the parent map's `access_keys_min_player_level`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_access_keys" do
    # "regular" | "pve": upstream publishes map data per mode.
    field :game_mode, :string, default: "regular"
    belongs_to :map, EftBuddy.Maps.Map
    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end
end
