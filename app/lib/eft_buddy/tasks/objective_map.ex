defmodule EftBuddy.Tasks.ObjectiveMap do
  @moduledoc """
  Join table linking an objective to one or more maps. Lets us
  represent multi-map tasks without flattening the API's per-objective
  `maps` list onto the parent task.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_objective_maps" do
    belongs_to :objective, EftBuddy.Tasks.Objective
    belongs_to :map, EftBuddy.Maps.Map

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:objective_id, :map_id])
    |> validate_required([:objective_id, :map_id])
    |> unique_constraint([:objective_id, :map_id])
    |> foreign_key_constraint(:objective_id)
    |> foreign_key_constraint(:map_id)
  end
end
