defmodule EftBuddy.Hideout.SkillRequirement do
  @moduledoc """
  Minimum character skill level required to build a hideout level
  (e.g. "Health 2" for Medstation lvl 2).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hideout_skill_requirements" do
    field :required_level, :integer

    belongs_to :level, EftBuddy.Hideout.StationLevel
    belongs_to :skill, EftBuddy.Hideout.Skill

    timestamps()
  end
end
