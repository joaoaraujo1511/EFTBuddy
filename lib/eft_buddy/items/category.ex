defmodule EftBuddy.Items.Category do
  use Ecto.Schema

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
end
