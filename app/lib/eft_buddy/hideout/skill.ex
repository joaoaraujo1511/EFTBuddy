defmodule EftBuddy.Hideout.Skill do
  @moduledoc """
  Character skills referenced by hideout level requirements (Health,
  Vitality, Strength, …).

  The Tarkov.dev API only returns the skill `name`. We derive
  `normalized_name` ourselves to match the convention used elsewhere
  in the codebase (lowercase, dash-separated). Promoting skills to
  their own table keeps the door open for a future skills/wiki
  feature without re-shaping hideout data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "skills" do
    field :name, :string
    field :normalized_name, :string

    has_many :skill_requirements, EftBuddy.Hideout.SkillRequirement, foreign_key: :skill_id

    timestamps()
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :normalized_name])
    |> validate_required([:name, :normalized_name])
    |> unique_constraint(:normalized_name)
  end
end
