defmodule EftBuddy.Hideout.SkillRequirement do
  @moduledoc """
  Minimum character skill level required to build a hideout level
  (e.g. "Health 2" for Medstation lvl 2).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_skill_requirements" do
    field :required_level, :integer

    belongs_to :level, EftBuddy.Hideout.StationLevel
    belongs_to :skill, EftBuddy.Hideout.Skill

    timestamps()
  end

  def changeset(req, attrs) do
    req
    |> cast(attrs, [:required_level, :level_id, :skill_id])
    |> validate_required([:required_level, :level_id, :skill_id])
    |> validate_number(:required_level, greater_than_or_equal_to: 1)
    |> unique_constraint([:level_id, :skill_id])
    |> foreign_key_constraint(:level_id)
    |> foreign_key_constraint(:skill_id)
  end
end
