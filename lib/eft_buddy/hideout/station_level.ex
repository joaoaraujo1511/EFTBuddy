defmodule EftBuddy.Hideout.StationLevel do
  @moduledoc """
  A specific level of a hideout station, with all of its requirements
  (items, prerequisite station levels, skills, traders).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_station_levels" do
    field :level, :integer

    belongs_to :station, EftBuddy.Hideout.Station

    has_many :item_requirements, EftBuddy.Hideout.ItemRequirement, foreign_key: :level_id

    has_many :station_level_requirements, EftBuddy.Hideout.StationLevelRequirement,
      foreign_key: :level_id

    has_many :skill_requirements, EftBuddy.Hideout.SkillRequirement, foreign_key: :level_id

    has_many :trader_requirements, EftBuddy.Hideout.TraderRequirement, foreign_key: :level_id

    timestamps()
  end

  def changeset(station_level, attrs) do
    station_level
    |> cast(attrs, [:level, :station_id])
    |> validate_required([:level, :station_id])
    |> validate_number(:level, greater_than_or_equal_to: 1)
    |> unique_constraint([:station_id, :level])
    |> foreign_key_constraint(:station_id)
  end
end
