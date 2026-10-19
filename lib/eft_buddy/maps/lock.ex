defmodule EftBuddy.Maps.Lock do
  @moduledoc """
  A locked door / container on a map (tarkov.dev `Lock`). `key_item`
  is the key that opens it — the link target for the Items tab. There
  is no natural unique key (a map can have several identical locks), so
  every lock is its own row.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_locks" do
    # "regular" | "pve": upstream publishes map data per mode.
    field :game_mode, :string, default: "regular"
    belongs_to :map, EftBuddy.Maps.Map

    field :lock_type, :string
    field :needs_power, :boolean

    belongs_to :key_item, EftBuddy.Items.Item, foreign_key: :key_item_id

    field :count, :integer, default: 1

    # Game-world position of a representative lock in the collapsed group
    # (Y is height; the viewer projects X/Z).
    field :pos_x, :float
    field :pos_y, :float
    field :pos_z, :float

    timestamps()
  end
end
