defmodule EftBuddy.Hideout.TraderRequirement do
  @moduledoc """
  Minimum trader loyalty level required to build a hideout level
  (e.g. "Therapist LL2" for Medstation lvl 2).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_trader_requirements" do
    field :required_level, :integer

    belongs_to :level, EftBuddy.Hideout.StationLevel
    belongs_to :trader, EftBuddy.Hideout.Trader

    timestamps()
  end
end
