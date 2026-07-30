defmodule EftBuddy.Wiki do
  @moduledoc """
  Read-only context for wiki walkthrough data scraped from the EFT
  Fandom wiki.

  Source of truth is the `wiki_quests` table, populated periodically by
  `EftBuddy.Wiki.Sync` (it scrapes the wiki, matches each page to an API
  task, and upserts a row). Images are NOT stored locally — each file
  entry carries a `url` pointing at the Fandom CDN, which the browser
  fetches directly.

  Lookups are keyed on the task's `normalized_name` slug (e.g.
  `"golden-swag"`) rather than its UUID. Slugs are derived from the
  quest title and survive a `mix ecto.reset` / re-sync; UUIDs do not.

  Public API (unchanged from when this was ETS-backed, so callers don't
  care where the data lives):

    * `get_quest/1`              — full projected map for one slug
    * `all_quests/0`             — lightweight rows (for the WIP merge)
    * `has_wiki?/1`              — is there any wiki content for this slug
    * `guide_for/1`              — ordered prose / image blocks
    * `objective_images_for/1`   — `%{1 => [files], ...}` by objective index
    * `karma_requirements/0`     — `%{slug => {:gte, n} | {:lte, n}}`

  The heavy manifest → render projection lives in
  `EftBuddy.Wiki.Projection` and runs on demand (per `get_quest/1`), not
  for every row, so there's no boot-time cache to keep warm.
  """

  import Ecto.Query

  alias EftBuddy.Repo
  alias EftBuddy.Wiki.{Projection, QuestPage}

  @type quest :: Projection.quest()

  @doc """
  Look up a single quest's projected wiki content by its normalized
  slug (e.g. `"golden-swag"`).

  Returns nil for unknown slugs and for tasks the wiki doesn't cover.
  Callers should treat nil as "render API content only", not an error.
  """
  @spec get_quest(String.t()) :: quest() | nil
  def get_quest(slug) when is_binary(slug) and slug != "" do
    case Repo.get_by(QuestPage, normalized_name: slug) do
      nil -> nil
      %QuestPage{content: content} -> Projection.project(content)
    end
  end

  def get_quest(_), do: nil

  @doc """
  Lightweight rows for every wiki quest, used by the Quests tab to
  append the wiki-only (WIP) quests to the unified list. Only the fields
  the WIP view-model needs are selected (no JSONB content is read).
  """
  @spec all_quests() :: [
          %{
            normalized_name: String.t(),
            task_name: String.t(),
            given_by: String.t() | nil,
            wip: boolean()
          }
        ]
  def all_quests do
    Repo.all(
      from(q in QuestPage,
        select: %{
          normalized_name: q.normalized_name,
          task_name: q.name,
          given_by: q.given_by,
          wip: q.wip
        }
      )
    )
  end

  @doc "Is there wiki content available for this slug?"
  @spec has_wiki?(String.t()) :: boolean()
  def has_wiki?(slug) when is_binary(slug) and slug != "" do
    Repo.exists?(from(q in QuestPage, where: q.normalized_name == ^slug))
  end

  def has_wiki?(_), do: false

  @doc """
  Ordered list of Guide-section blocks in document order, ready to
  render (`:heading` / `:prose` / `:gallery`). Empty list when the quest
  has no Guide section or no manifest at all.
  """
  @spec guide_for(String.t()) :: [map()]
  def guide_for(slug) do
    case get_quest(slug) do
      nil -> []
      %{guide: blocks} -> blocks
    end
  end

  @doc """
  Map from API-objective index (1-based) to the list of wiki file refs
  anchored to that objective. Empty map for tasks whose wiki Objectives
  section had no images (the common case).
  """
  @spec objective_images_for(String.t()) :: %{integer() => [map()]}
  def objective_images_for(slug) do
    case get_quest(slug) do
      nil -> %{}
      %{objective_images: map} -> map
    end
  end

  @doc """
  `%{slug => karma_requirement_tuple}` for every quest with a parsed
  scav-karma threshold. Read straight from the denormalised
  `karma_kind` / `karma_value` columns, so this is a single cheap query
  rather than a fold over every quest's parsed content.

  Tuple shapes: `{:gte, n}` (needs `karma ≥ n`) and `{:lte, n}` (needs
  `karma ≤ n`).
  """
  @spec karma_requirements() :: %{String.t() => {:gte | :lte, integer()}}
  def karma_requirements do
    Repo.all(
      from(q in QuestPage,
        where: not is_nil(q.karma_kind),
        select: {q.normalized_name, q.karma_kind, q.karma_value}
      )
    )
    |> Map.new(fn {slug, kind, value} -> {slug, {kind_to_atom(kind), value}} end)
  end

  defp kind_to_atom("gte"), do: :gte
  defp kind_to_atom("lte"), do: :lte
end
