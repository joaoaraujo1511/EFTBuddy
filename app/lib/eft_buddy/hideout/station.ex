defmodule EftBuddy.Hideout.Station do
  @moduledoc """
  A hideout station (Medstation, Stash, Generator, …). Each station
  has a fixed set of levels with their own requirements; see
  `EftBuddy.Hideout.StationLevel`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_stations" do
    field :name, :string
    field :normalized_name, :string

    has_many :levels, EftBuddy.Hideout.StationLevel, foreign_key: :station_id

    timestamps()
  end

  def changeset(station, attrs) do
    station
    |> cast(attrs, [:name, :normalized_name])
    |> validate_required([:name, :normalized_name])
    |> unique_constraint(:normalized_name)
  end
end
