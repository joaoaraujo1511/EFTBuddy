defmodule EftBuddyWeb.StorylineLive.Show do
  use EftBuddyWeb, :live_view

  import EftBuddyWeb.StorylineComponents

  alias EftBuddy.Chapters
  alias EftBuddy.Items

  # The "Endings" overview (descriptions, rewards, and the Smokey
  # flowchart) belongs on the endgame chapter where the four endings
  # branch - everywhere else it would be noise.
  @endings_chapter "the-ticket"

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Chapters.get_chapter(slug) do
      nil ->
        # Unknown chapter - bounce back to the index rather than 500.
        {:ok,
         socket
         |> put_flash(:error, "That storyline chapter doesn't exist.")
         |> push_navigate(to: ~p"/storyline")}

      chapter ->
        endings = endings_for(chapter)

        {:ok,
         socket
         |> assign(:page_title, chapter.chapter_name)
         |> assign(
           :page_description,
           chapter.summary ||
             "Walkthrough, related quests and gallery for the #{chapter.chapter_name} chapter of the Escape from Tarkov storyline."
         )
         |> assign(:active, :storyline)
         |> assign(:view, "walkthrough")
         |> assign(:chapter, chapter)
         |> assign(:related_tasks, related_tasks(chapter))
         |> assign(:endings, endings)
         |> assign(:item_index, build_item_index(chapter, endings))
         |> assign(:tabs, tabs(chapter, endings))}
    end
  end

  # Resolve every related-item name the page can render (the chapter's
  # items + the endings' items) to real DB items in one query, as a
  # `%{page => item}` map. The components use it to link/illustrate only
  # genuine items and leave wiki concept links ("building materials", ...)
  # as plain text. Degrades to no resolution if the item DB is
  # unavailable (everything then renders as plain text).
  defp build_item_index(chapter, endings) do
    ending_items = if endings, do: endings.items, else: []

    (chapter.items ++ ending_items)
    |> Enum.map(& &1.page)
    |> Items.resolve_wiki_items()
  rescue
    # Storyline is wiki-only; tolerate the item DB being down or
    # un-migrated, but let genuine bugs crash rather than silently
    # rendering an empty index.
    _ in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] -> %{}
  end

  # The options-bar tabs for this chapter: always the walkthrough, plus
  # the endings overview where it applies. Each tab patches `?view=` so
  # navigation flows through `handle_params/3`.
  #
  # Because the walkthrough is the only tab on every chapter but the
  # endgame one, the template only renders the bar when there is more
  # than one tab - so most chapters show no options bar at all.
  defp tabs(chapter, endings) do
    slug = chapter.normalized_name

    [
      %{
        label: "WALKTHROUGH",
        icon: "hero-book-open",
        patch: ~p"/storyline/#{slug}",
        filter: "walkthrough"
      },
      endings &&
        %{
          label: "ENDINGS",
          icon: "hero-rectangle-group",
          patch: ~p"/storyline/#{slug}?#{[view: "endings"]}",
          filter: "endings"
        }
    ]
    |> Enum.filter(& &1)
  end

  # The options bar switches the page between the walkthrough and (where
  # it applies) the endings overview. The selected view lives in `?view=`
  # so it's shareable and refresh-safe, and we fall back to the
  # walkthrough whenever the requested view isn't available for this
  # chapter.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :view, normalize_view(params["view"], socket.assigns))}
  end

  defp normalize_view(view, assigns) do
    if view == "endings" and assigns[:endings], do: "endings", else: "walkthrough"
  end

  # Load the dumped "Endings" page only for the chapter where the endings
  # branch; nil elsewhere (and if it hasn't been dumped/loaded).
  defp endings_for(%{normalized_name: @endings_chapter}), do: Chapters.get_endings()
  defp endings_for(_), do: nil

  # Keep only the chapter's wiki references that resolve to a real DB
  # task, carrying the task's display name for the `/tasks?q=` deep-link.
  # Degrades to no cross-links if the task DB isn't synced/available.
  defp related_tasks(chapter) do
    index = task_index()

    chapter.related_links
    |> Enum.filter(fn link -> Map.has_key?(index, link.slug) end)
    |> Enum.map(fn link -> %{slug: link.slug, name: Map.fetch!(index, link.slug)} end)
    |> Enum.uniq_by(& &1.slug)
  end
end
