defmodule EftBuddy.Tasks.Objective do
  @moduledoc """
  A single task objective.

  The Tarkov.dev API exposes objectives as a `TaskObjective`
  interface with 14 concrete subtypes (Item, Extract, Shoot, …).
  Rather than maintain 14 tables we store the discriminator in
  `type` and the subtype-specific fields in a `payload` JSONB map.
  The Sync module picks per-type fields from the API response and
  drops them into `payload`; the LiveView pattern-matches on `type`
  to render.

  Common fields (`type`, `description`, `optional`, `maps`) are
  promoted to columns / joins because the UI needs them across all
  subtypes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "task_objectives" do
    field :external_id, :string
    field :type, :string
    field :description, :string
    field :optional, :boolean, default: false
    field :payload, :map, default: %{}
    # 0-based position within the parent task's objective list, set
    # from the API response order at sync time. Sort on this — never
    # on inserted_at — when rendering objectives for a task.
    field :position, :integer

    belongs_to :task, EftBuddy.Tasks.Task

    has_many :objective_maps, EftBuddy.Tasks.ObjectiveMap, foreign_key: :objective_id
    has_many :maps, through: [:objective_maps, :map]

    timestamps()
  end

  def changeset(objective, attrs) do
    objective
    |> cast(attrs, [
      :external_id,
      :type,
      :description,
      :optional,
      :payload,
      :position,
      :task_id
    ])
    |> validate_required([:external_id, :type, :task_id])
    |> unique_constraint([:task_id, :external_id],
      name: :task_objectives_task_external_id_index
    )
    |> foreign_key_constraint(:task_id)
  end
end
