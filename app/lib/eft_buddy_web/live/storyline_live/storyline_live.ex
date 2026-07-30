defmodule EftBuddyWeb.StorylineLive.Index do
  use EftBuddyWeb, :live_view

  import EftBuddyWeb.StorylineComponents

  alias EftBuddy.Chapters
  alias EftBuddy.Items

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Storyline")
      |> assign(
        :page_description,
        "The Escape from Tarkov storyline, chapter by chapter: walkthroughs, related quests and the four endings."
      )
      |> assign(:active, :storyline)
      |> assign(:view, "chapters")
      |> assign(:query, "")
      |> load_storyline_data()
      |> assign_visible_chapters()

    {:ok, socket}
  end

  # Derive the search-filtered chapter timeline into an assign so the
  # template stays declarative. Chapters are loaded once (they don't mutate
  # after mount), so this only needs recomputing when the search changes.
  defp assign_visible_chapters(socket) do
    assign(
      socket,
      :visible_chapters,
      visible_chapters(socket.assigns.chapters, socket.assigns.query)
    )
  end

  # Load the chapter timeline + endings only on the connected mount so
  # the work isn't repeated on the disconnected (static) render. The
  # page shows an empty timeline for a blink, then fills in on connect.
  defp load_storyline_data(socket) do
    if connected?(socket) do
      index = task_index()
      endings = Chapters.get_endings()

      chapters =
        Chapters.list_chapters()
        |> Enum.with_index(1)
        |> Enum.map(fn {chapter, number} -> build_view_model(chapter, number, index) end)

      socket
      |> assign(:chapters, chapters)
      |> assign(:endings, endings)
      |> assign(:item_index, build_item_index(endings))
    else
      socket
      |> assign(:chapters, [])
      |> assign(:endings, nil)
      |> assign(:item_index, %{})
    end
  end

  # Resolve the endings' related items to real DB items (the only items
  # the index renders, under the Endings view). Degrades to no
  # resolution if the item DB is unavailable.
  defp build_item_index(nil), do: %{}

  defp build_item_index(endings) do
    endings.items |> Enum.map(& &1.page) |> Items.resolve_wiki_items()
  rescue
    # Storyline is wiki-only; tolerate the item DB being down or
    # un-migrated, but let genuine bugs crash rather than silently
    # rendering an empty index.
    _ in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] -> %{}
  end

  # The index has two views: the chapter timeline (default) and the
  # endings overview, toggled by the options bar via `?view=`. A `?q=`
  # search term (matched against chapter names/summaries/related tasks)
  # narrows the timeline.
  @impl true
  def handle_params(params, _uri, socket) do
    view =
      if params["view"] == "endings" and socket.assigns.endings, do: "endings", else: "chapters"

    query =
      params
      |> Map.get("q", "")
      |> to_string()
      |> String.slice(0, 200)

    {:noreply,
     socket |> assign(:view, view) |> assign(:query, query) |> assign_visible_chapters()}
  end

  # The search box patches the URL (preserving the active view) so
  # `handle_params/3` stays the single source of truth and the view is
  # shareable/refreshable. `replace: true` keeps history clean.
  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: storyline_path(socket.assigns.view, query), replace: true)}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: storyline_path(socket.assigns.view, ""), replace: true)}
  end

  @doc """
  Builds a `/storyline` path preserving the active view + search term.
  Defaults (`"chapters"` view, blank query) are dropped so the bare URL
  stays clean.
  """
  def storyline_path(view, query) do
    params =
      []
      |> then(fn p -> if view == "endings", do: p ++ [view: "endings"], else: p end)
      |> then(fn p -> if query in [nil, ""], do: p, else: p ++ [q: query] end)

    case params do
      [] -> ~p"/storyline"
      _ -> ~p"/storyline?#{params}"
    end
  end

  @doc """
  Filters the chapter timeline by a free-text query, matching the chapter
  name, summary and any related task names. A blank query returns all
  chapters unchanged.
  """
  def visible_chapters(chapters, query) when query in [nil, ""], do: chapters

  def visible_chapters(chapters, query) do
    needle = String.downcase(query)

    Enum.filter(chapters, fn chapter ->
      [chapter.chapter_name, chapter.summary | Enum.map(chapter.related_tasks || [], & &1.name)]
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()
      |> String.contains?(needle)
    end)
  end

  # Cross-link the chapter's wiki references to real tasks: keep only
  # the `related_links` whose slug is backed by a DB task, carrying the
  # task's display name for the `/tasks?q=` deep-link. `related_links`
  # also includes maps/items/notes, which simply don't match here.
  defp build_view_model(chapter, number, task_index) do
    related_tasks =
      chapter.related_links
      |> Enum.filter(fn link -> Map.has_key?(task_index, link.slug) end)
      |> Enum.map(fn link -> %{slug: link.slug, name: Map.fetch!(task_index, link.slug)} end)
      |> Enum.uniq_by(& &1.slug)

    chapter
    |> Map.put(:number, number)
    |> Map.put(:related_tasks, related_tasks)
  end
end
