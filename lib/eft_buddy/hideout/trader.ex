defmodule EftBuddy.Hideout.Trader do
  @moduledoc """
  Tarkov traders (Therapist, Skier, Prapor, …).

  Modelled as a first-class entity so other features (wiki, trader
  loyalty tracking, etc.) can reference them later. For the hideout
  feature only `name` and `normalized_name` are needed; columns can
  be added incrementally without touching this code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "traders" do
    field :name, :string
    field :normalized_name, :string
    field :image_link, :string

    has_many :trader_requirements, EftBuddy.Hideout.TraderRequirement, foreign_key: :trader_id

    timestamps()
  end

  def changeset(trader, attrs) do
    trader
    |> cast(attrs, [:name, :normalized_name, :image_link])
    |> validate_required([:name, :normalized_name])
    |> unique_constraint(:normalized_name)
  end
end
