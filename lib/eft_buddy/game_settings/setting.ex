defmodule EftBuddy.GameSettings.Setting do
  @moduledoc """
  A single key/value game constant row (see `EftBuddy.GameSettings`).
  Only integer values are modelled today (`int_value`); add typed
  columns here if a non-integer setting ever needs persisting.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "game_settings" do
    field :key, :string
    field :int_value, :integer

    timestamps()
  end
end
