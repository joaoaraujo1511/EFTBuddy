defmodule EftBuddy.Items.Category do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "categories" do
    field :external_id, :string
    field :name, :string
    field :normalized_name, :string
    field :image_link, :string
    field :min_level_for_flea_market, :integer

    has_many :items, EftBuddy.Items.Item, foreign_key: :category_id

    timestamps()
  end

  @doc """
  Creates a changeset for category creation from API data.

  ## Examples
      Category.changeset(%Category{}, %{
        external_id: "5ac66cb05acfc400192632fc",
        name: "Assault Rifles"
      })
  """
  def changeset(category, attrs) do
    category
    |> cast(attrs, [
      :external_id,
      :name,
      :normalized_name,
      :image_link,
      :min_level_for_flea_market
    ])
    |> validate_required([:external_id, :name])
    |> unique_constraint(:external_id)
  end

  @doc """
  Creates a changeset for updating categories.
  """
  def update_changeset(category, attrs) do
    category
    |> cast(attrs, [
      :name,
      :normalized_name,
      :image_link,
      :min_level_for_flea_market
    ])
  end
end
