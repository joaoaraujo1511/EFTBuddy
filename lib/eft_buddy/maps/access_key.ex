defmodule EftBuddy.Maps.AccessKey do
  @moduledoc """
  Join row: a key item required to access a map (tarkov.dev
  `Map.accessKeys`). `item` is the link target for the Items tab; the
  PMC-level gate lives on the parent map's `access_keys_min_player_level`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "map_access_keys" do
    belongs_to :map, EftBuddy.Maps.Map
    belongs_to :item, EftBuddy.Items.Item

    timestamps()
  end

  def changeset(access_key, attrs) do
    access_key
    |> cast(attrs, [:map_id, :item_id])
    |> validate_required([:map_id, :item_id])
    |> unique_constraint([:map_id, :item_id])
    |> foreign_key_constraint(:map_id)
    |> foreign_key_constraint(:item_id)
  end
end
