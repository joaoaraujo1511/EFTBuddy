defmodule EftBuddy.Repo.Migrations.AddImageVariantsToMaps do
  use Ecto.Migration

  @moduledoc """
  Adds the static map-image variants (the flat "2D" and "3D" renders)
  sourced from tarkov.dev's `maps.json` at sync time.

  The GraphQL/JSON data API exposes no map imagery, so — like `svg_path`
  — these come from `maps.json`. Each projection group there lists any
  number of `2D` / `3D` renders (e.g. `customs-3d`, `customs-3d-dorms`);
  we snapshot the per-projection list so the in-app viewer can offer a
  2D / 3D toggle and loop through variant renders.

  Shape (string-keyed, JSON-ready), e.g.:

      %{
        "2d" => [%{"key" => "customs-2d", "url" => "…/customs-2d.jpg",
                   "label" => "2D", "author" => "…"}],
        "3d" => [%{"key" => "customs-3d", "url" => "…", "label" => "3D", …},
                 %{"key" => "customs-3d-dorms", "url" => "…",
                   "label" => "Dorms", …}]
      }

  Nullable-ish: defaults to an empty map, so maps `maps.json` carries no
  static renders for (or that predate the first `Maps.Sync` run) stay
  valid.
  """

  def change do
    alter table(:maps) do
      add :image_variants, :map, null: false, default: %{}
    end
  end
end
