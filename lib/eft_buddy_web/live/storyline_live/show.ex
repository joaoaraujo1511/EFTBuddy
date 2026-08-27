defmodule EftBuddyWeb.StorylineLive.Show do
  use EftBuddyWeb, :live_view

  import EftBuddyWeb.StorylineComponents

  alias EftBuddy.Chapters

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
        # The endgame chapter's page is the guide and payout for whichever
        # ending you are pursuing. The objectives are not repeated here - each
        # guide covers them - and which branch leads where is the storyline
        # index's Endings tab. Every other chapter keeps its walkthrough.
        ending_views = Chapters.ending_views(chapter)

        {:ok,
         socket
         |> assign(:page_title, chapter.chapter_name)
         |> assign(
           :page_description,
           chapter.summary ||
             "Walkthrough, related quests and gallery for the #{chapter.chapter_name} chapter of the Escape from Tarkov storyline."
         )
         |> assign(:active, :storyline)
         |> assign(:chapter, chapter)
         |> assign(:related_tasks, related_tasks(chapter))
         |> assign(:ending_views, ending_views)
         |> assign(:ending, nil)
         |> assign(:counts, counts(chapter, ending_views, nil))
         # The rewards under each ending are scraped from the Endings wiki
         # page, not from this chapter's, so they carry their own credit.
         |> assign(:endings, if(ending_views != [], do: Chapters.get_endings()))
         |> assign(:item_index, build_item_index())}
    end
  end

  # The header's tallies describe what is on screen. For the endgame
  # chapter that is one ending's guide and payout, not the four the page
  # could show; everywhere else it is the whole walkthrough.
  defp counts(chapter, ending_views, ending) do
    case Enum.find(ending_views, &(&1.slug == ending)) do
      nil -> %{objectives: chapter.objective_count, images: chapter.image_count}
      view -> view.counts
    end
  end

  # Which ending the reader is pursuing. It lives in `?ending=` so it is
  # shareable and refresh-safe - and so the storyline index can hand the
  # reader straight to the one they picked - and an unknown or missing
  # value falls back to the first rather than blanking the page.
  @impl true
  def handle_params(params, _uri, socket) do
    %{chapter: chapter, ending_views: views} = socket.assigns
    ending = normalize_ending(params["ending"], views)

    {:noreply,
     socket |> assign(:ending, ending) |> assign(:counts, counts(chapter, views, ending))}
  end

  defp normalize_ending(_slug, []), do: nil

  defp normalize_ending(slug, [first | _] = views) do
    if Enum.any?(views, &(&1.slug == slug)), do: slug, else: first.slug
  end

  # Resolve every related-item name the page can render (the chapter's
  # items + the endings' items) to real DB items in one query, as a
  # `%{page => item}` map. The components use it to link/illustrate only
  # genuine items and leave wiki concept links ("building materials", ...)
  # as plain text. Degrades to no resolution if the item DB is
  # unavailable (everything then renders as plain text).
  defp build_item_index do
    # One shared index for every chapter rather than one built per page. The
    # components only do `Map.get(index, page)`, so a superset resolves
    # identically — and this one is cached and warmed, where a per-chapter index
    # would be keyed on a list of page names.
    Chapters.item_index()
  rescue
    # Storyline is wiki-only; tolerate the item DB being down or
    # un-migrated, but let genuine bugs crash rather than silently
    # rendering an empty index.
    _ in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] -> %{}
  end

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
