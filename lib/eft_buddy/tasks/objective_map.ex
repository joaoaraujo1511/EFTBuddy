defmodule EftBuddy.Tasks.ObjectiveMap do
  @moduledoc """
  Join table linking an objective to one or more maps. Lets us
  represent multi-map tasks without flattening the API's per-objective
  `maps` list onto the parent task.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_objective_maps" do
    belongs_to :objective, EftBuddy.Tasks.Objective
    belongs_to :map, EftBuddy.Maps.Map

    timestamps()
  end
end
