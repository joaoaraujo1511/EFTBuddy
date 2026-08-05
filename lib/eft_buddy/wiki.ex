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

  alias EftBuddy.Cache
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
    # Guarded on the slug SET rather than cached directly on `slug`.
    #
    # Two reasons, and the second is the important one. First, key-space:
    # `wiki_lookup_slugs/1` in the Tasks LiveView derives up to three candidate
    # slugs per task from its name, so caching every lookup would mint ~3,000
    # entries, most of them `nil`, keyed on strings no wiki row will ever match.
    #
    # Second, and this is what a plain `Cache.fetch` would not fix: `task_wiki/1`
    # probes those candidates with `Enum.find_value/2`, so MOST calls here are
    # misses by construction. Testing membership of an already-cached set makes
    # a miss cost zero round trips instead of one, which is most of the win on a
    # quest expand.
    if MapSet.member?(quest_slugs(), slug) do
      Cache.fetch({__MODULE__, :quest, slug}, ["WikiSync"], fn ->
        case Repo.get_by(QuestPage, normalized_name: slug) do
          nil -> nil
          %QuestPage{content: content} -> Projection.project(content)
        end
      end)
    end
  end

  def get_quest(_), do: nil

  @doc false
  # Precompute every quest's projected content.
  #
  # One query for all of them, then one `Projection.project/1` per row. The
  # projection is the expensive half — it walks each page's stored manifest —
  # and doing it here means a quest expand never pays for it.
  def warm_quests do
    rows =
      Repo.all(from(q in QuestPage, select: {q.normalized_name, q.content}))

    rows
    |> Enum.chunk_every(Cache.warm_chunk_size())
    |> Enum.each(fn chunk ->
      entries =
        Enum.map(chunk, fn {slug, content} ->
          {{__MODULE__, :quest, slug}, Projection.project(content)}
        end)

      Cache.put_many(entries, ["WikiSync"])
      Process.sleep(Cache.warm_chunk_pause_ms())
    end)

    {:ok, length(rows)}
  end

  @doc false
  # The set of slugs `wiki_quests` actually has a row for.
  #
  # Derived from the already-cached, already-warmed `all_quests/0`, so it costs
  # no extra query — and it is what keeps `{Wiki, :quest, slug}` keyed on rows
  # that exist rather than on every string a caller can construct.
  def quest_slugs do
    Cache.fetch({__MODULE__, :quest_slugs}, ["WikiSync"], fn ->
      MapSet.new(all_quests(), & &1.normalized_name)
    end)
  end

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
    # Read once per Tasks-page mount and used twice there (the has_wiki? badges
    # and the WIP rows), so it is on the critical path of the app's busiest page.
    Cache.fetch({__MODULE__, :all_quests}, ["WikiSync"], &all_quests_uncached/0)
  end

  defp all_quests_uncached do
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
    # A set membership test, not a `Repo.exists?`. It has no callers in `lib/`
    # today, but the per-task version of exactly this query is what once made a
    # `/tasks` mount cost 500-1200 round trips — leaving a queryful
    # implementation here invites that straight back the next time someone needs
    # a badge.
    MapSet.member?(quest_slugs(), slug)
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
    # On the connected mount of `/tasks`, which is the app's landing page, so
    # this ran on every arrival.
    Cache.fetch({__MODULE__, :karma_requirements}, ["WikiSync"], &karma_requirements_uncached/0)
  end

  defp karma_requirements_uncached do
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
