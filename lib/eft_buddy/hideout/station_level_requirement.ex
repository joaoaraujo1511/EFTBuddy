defmodule EftBuddy.Hideout.StationLevelRequirement do
  @moduledoc """
  "This level requires another station to be at least at level X."

  Self-referential to `Station` (not `StationLevel`) because the API
  expresses the dependency in terms of "Generator at lvl ≥ 1" — any
  level of the player's Generator that meets or exceeds `required_level`
  satisfies it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_station_level_requirements" do
    field :required_level, :integer

    belongs_to :level, EftBuddy.Hideout.StationLevel

    belongs_to :required_station, EftBuddy.Hideout.Station, foreign_key: :required_station_id

    timestamps()
  end

  def changeset(req, attrs) do
    req
    |> cast(attrs, [:required_level, :level_id, :required_station_id])
    |> validate_required([:required_level, :level_id, :required_station_id])
    |> validate_number(:required_level, greater_than_or_equal_to: 1)
    |> unique_constraint([:level_id, :required_station_id],
      name: :hideout_station_level_reqs_level_required_station_index
    )
    |> foreign_key_constraint(:level_id)
    |> foreign_key_constraint(:required_station_id)
  end
end
