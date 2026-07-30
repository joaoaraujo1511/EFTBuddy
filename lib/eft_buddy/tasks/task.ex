defmodule EftBuddy.Tasks.Task do
  @moduledoc """
  A Tarkov quest. Top-level entity for the tasks domain.

  Field naming mirrors the Tarkov.dev `Task` GraphQL type
  (snake_case). The `map_id` column is the *primary* map per the API
  and may be `nil` for multi-map tasks; per-objective maps are
  modelled via `EftBuddy.Tasks.ObjectiveMap`.

  Trader / skill / item references reuse existing schemas
  (`EftBuddy.Hideout.Trader`, `EftBuddy.Hideout.Skill`,
  `EftBuddy.Items.Item`) so we don't duplicate that data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tasks" do
    field :external_id, :string
    field :name, :string
    field :normalized_name, :string

    # PVP (`"regular"`) or PVE (`"pve"`). Part of the identity of a
    # task: the same tarkov.dev id can exist once per mode with
    # different requirements. See `EftBuddy.GameMode`.
    field :game_mode, :string, default: "regular"

    field :wiki_link, :string
    field :task_image_link, :string
    field :faction_name, :string

    field :experience, :integer
    field :min_player_level, :integer

    field :kappa_required, :boolean, default: false
    field :lightkeeper_required, :boolean, default: false
    field :restartable, :boolean, default: false

    belongs_to :trader, EftBuddy.Hideout.Trader
    belongs_to :map, EftBuddy.Maps.Map

    has_many :objectives, EftBuddy.Tasks.Objective, foreign_key: :task_id

    has_many :trader_requirements, EftBuddy.Tasks.TraderRequirement, foreign_key: :task_id
    has_many :task_requirements, EftBuddy.Tasks.TaskRequirement, foreign_key: :task_id

    # Tasks unlocked by completing this task. Populated at sync time.
    has_many :unlocks, EftBuddy.Tasks.Unlock, foreign_key: :prerequisite_task_id

    # Tasks whose completion unlocks this task (inverse of `unlocks`).
    has_many :unlocked_by, EftBuddy.Tasks.Unlock, foreign_key: :unlocked_task_id

    has_many :item_rewards, EftBuddy.Tasks.ItemReward, foreign_key: :task_id

    has_many :trader_standing_rewards, EftBuddy.Tasks.TraderStandingReward, foreign_key: :task_id

    has_many :skill_rewards, EftBuddy.Tasks.SkillReward, foreign_key: :task_id
    has_many :trader_unlocks, EftBuddy.Tasks.TraderUnlock, foreign_key: :task_id
    has_many :offer_unlocks, EftBuddy.Tasks.OfferUnlock, foreign_key: :task_id

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :external_id,
      :name,
      :normalized_name,
      :game_mode,
      :wiki_link,
      :task_image_link,
      :faction_name,
      :experience,
      :min_player_level,
      :kappa_required,
      :lightkeeper_required,
      :restartable,
      :trader_id,
      :map_id
    ])
    |> validate_required([:external_id, :name, :normalized_name, :game_mode])
    |> unique_constraint([:external_id, :game_mode],
      name: :tasks_external_id_game_mode_index
    )
    |> unique_constraint([:normalized_name, :game_mode],
      name: :tasks_normalized_name_game_mode_index
    )
    |> foreign_key_constraint(:trader_id)
    |> foreign_key_constraint(:map_id)
  end
end
