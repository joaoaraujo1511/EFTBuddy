defmodule EftBuddy.Chapters do
  @moduledoc """
  Read-only context for storyline-chapter data scraped from the EFT
  Fandom wiki.

  Source of truth is the `wiki_chapters` table, populated periodically by
  `EftBuddy.Chapters.Sync` (it scrapes the wiki and upserts a row per
  chapter). Images are NOT stored locally — each file entry carries a
  `url` pointing at the Fandom CDN, which the browser fetches directly.

  Storyline mirror of `EftBuddy.Wiki`: chapters are wiki-only editorial
  pages (no tarkov.dev task behind them), keyed on a `normalized_name`
  slug (e.g. `"boreas"`) that survives a `mix ecto.reset` / re-sync.

  Public API (unchanged from when this was ETS-backed, so callers don't
  care where the data lives):

    * `list_chapters/0`    — every chapter in curated narrative order
    * `get_chapter/1`      — one prepared chapter by slug
    * `get_endings/0`      — the "Endings" reference page
    * `chapters_for_item/1`— chapters that reference a given item

  The heavy manifest → render projection lives in
  `EftBuddy.Chapters.Projection` and runs on demand (per lookup), not at
  boot — there are only ~10 chapters and each parse is cheap.

  ## Ordering

  `Category:Story chapters` is an unordered set and the wiki encodes no
  reliable sequence (infoboxes don't chain; the hub/navbox are
  alphabetical; the chapters branch into four endings). So the
  narrative order is a curated editorial list, `@order` below — cheap to
  maintain (it only changes when BSG ships a new chapter). Chapters not
  in the list sort after the curated ones, alphabetically, so a newly
  synced chapter still renders without a code change.
  """

  import Ecto.Query

  alias EftBuddy.Cache
  alias EftBuddy.Repo
  alias EftBuddy.Chapters.{ChapterPage, Projection}

  # Slug of the "Endings" reference page. It's scraped through the same
  # pipeline as the chapters (so its content comes from the wiki too) but
  # it is NOT a story chapter: it's excluded from the narrative timeline
  # and surfaced on its own via `get_endings/0` for the storyline
  # "Endings" tab.
  @endings_slug "endings"

  # Curated narrative order, by slug. `Tour` is the Ground Zero tutorial
  # (the entry point); `The Ticket` is the endgame that branches into
  # the four endings. The middle is the rough progression order — adjust
  # freely, it's pure editorial metadata.
  @order ~w(
    tour
    blue-fire
    accidental-witness
    they-are-already-here
    batya
    falling-skies
    boreas
    the-unheard
    the-labyrinth
    the-ticket
  )

  @typedoc "A prepared chapter, or nil when the slug is unknown."
  @type chapter :: EftBuddy.Chapters.Projection.chapter()

  @doc """
  Every chapter, in curated narrative order (see module doc).

  Excludes the "Endings" reference page (surfaced via `get_endings/0`).
  Returns `[]` when no chapters have been synced yet.
  """
  @spec list_chapters() :: [chapter()]
  def list_chapters do
    # The 761ms here is one query returning ~2.4MB, plus a `Projection.project/1`
    # per chapter — so caching saves the CPU of re-projecting the same wiki
    # markup as well as the round trip.
    Cache.fetch({__MODULE__, :list_chapters}, ["ChaptersSync"], &list_chapters_uncached/0)
  end

  defp list_chapters_uncached do
    Repo.all(from(c in ChapterPage, where: c.normalized_name != @endings_slug))
    |> Enum.map(fn %ChapterPage{content: content} -> Projection.project(content) end)
    |> Enum.sort_by(&order_key/1)
  end

  @doc """
  The "Endings" reference page (the four story endings — descriptions,
  rewards, and the flowchart image — pulled from the wiki by the sync),
  prepared the same way as a chapter. Returns nil if it hasn't been
  synced. Shown under the storyline "Endings" tab.
  """
  @spec get_endings() :: chapter() | nil
  def get_endings do
    case get_chapter(@endings_slug) do
      nil -> nil
      chapter -> %{chapter | content_sections: condense_endings(chapter.content_sections)}
    end
  end

  # The scraped "Endings" page renders as nine sections — a leading
  # "Image Guides" flowchart, then each of the four endings (Savior,
  # Debtor, Survivor, Fallen) followed by its own level-3 "Rewards"
  # subsection. That reads as nine containers (and a misleading "9" count)
  # when there are only four endings. Condense it for display:
  #
  #   * drop the "Image Guides" section entirely (the flowchart is still
  #     scraped/stored by the sync — it's just not rendered here), and
  #   * fold each ending's "Rewards" subsection back into the ending it
  #     belongs to, as a "Rewards" sub-heading,
  #
  # so the Endings tab shows exactly one container per ending. Purely a
  # presentation transform over the projected sections; the sync/dump and
  # stored manifest are untouched.
  defp condense_endings(content_sections) do
    content_sections
    |> Enum.reject(&image_guides_section?/1)
    |> Enum.reduce([], fn section, acc ->
      if reward_subsection?(section) and acc != [] do
        [parent | rest] = acc
        [fold_rewards_into(parent, section) | rest]
      else
        [section | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp image_guides_section?(%{heading: heading}),
    do: normalized_heading(heading) == "image guides"

  defp image_guides_section?(_), do: false

  # A level-3+ "Rewards" subsection belongs to the ending heading above it.
  defp reward_subsection?(%{heading: heading, level: level}),
    do: level >= 3 and normalized_heading(heading) == "rewards"

  defp reward_subsection?(_), do: false

  defp fold_rewards_into(parent, reward) do
    rewards_heading = %{kind: :heading, level: 3, text: "Rewards"}
    %{parent | blocks: parent.blocks ++ [rewards_heading | reward.blocks]}
  end

  defp normalized_heading(heading) when is_binary(heading),
    do: heading |> String.trim() |> String.downcase()

  defp normalized_heading(_), do: ""

  @doc """
  Look up a single chapter's prepared content by its normalized slug
  (e.g. `"boreas"`). Returns nil for unknown slugs.
  """
  @spec get_chapter(String.t()) :: chapter() | nil
  def get_chapter(slug) when is_binary(slug) and slug != "" do
    case Repo.get_by(ChapterPage, normalized_name: slug) do
      nil -> nil
      %ChapterPage{content: content} -> Projection.project(content)
    end
  end

  def get_chapter(_), do: nil

  @doc """
  Storyline chapters that reference a given item, as
  `[%{slug, title}]` in narrative order.

  Used by the Items tab to cross-link an item back to the chapter(s)
  that feature it (the inverse of the chapter "Related items" lists).
  Matching is by name: the wiki "Related Quest Items" page title (and
  display name) is normalised the same way as the DB item name, so the
  `#`-vs-space / case differences between the two sources don't matter.
  Returns `[]` when the item isn't referenced by any chapter.
  """
  @spec chapters_for_item(%{optional(any) => any}) :: [%{slug: String.t(), title: String.t()}]
  def chapters_for_item(%{name: name}) when is_binary(name) and name != "" do
    target = normalize_item_name(name)

    list_chapters()
    |> Enum.filter(fn chapter ->
      Enum.any?(chapter.items, fn item ->
        normalize_item_name(item.page) == target or normalize_item_name(item.name) == target
      end)
    end)
    |> Enum.map(fn chapter -> %{slug: chapter.normalized_name, title: chapter.chapter_name} end)
  end

  def chapters_for_item(_), do: []

  # ── Private ────────────────────────────────────────────────────────

  # Reduce an item name to a comparable token string: lowercase,
  # punctuation (incl. the wiki `#` issue markers) collapsed to single
  # spaces, trimmed. Applied to both the DB item name and the wiki
  # page/display name so the two reconcile regardless of formatting.
  defp normalize_item_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp normalize_item_name(_), do: ""

  # Curated chapters sort by their position in @order; anything not
  # listed sorts after them (index = list length) and is tie-broken
  # alphabetically by name, so unknown/new chapters still render.
  defp order_key(%{normalized_name: slug, chapter_name: name}) do
    index =
      case Enum.find_index(@order, &(&1 == slug)) do
        nil -> length(@order)
        i -> i
      end

    {index, name || ""}
  end
end
