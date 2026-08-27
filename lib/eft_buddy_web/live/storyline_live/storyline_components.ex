defmodule EftBuddyWeb.StorylineComponents do
  @moduledoc """
  Shared function components for the storyline tab - used by both the index
  (`StorylineLive.Index`) and the chapter detail page (`StorylineLive.Show`).
  Restyled to the OPERATOR HUD design language; the parsing/data shape is
  unchanged.
  """
  use EftBuddyWeb, :html

  alias EftBuddy.Tasks

  @doc """
  `%{slug => name}` for every DB task, used by both storyline views to
  resolve chapter cross-links to real `/tasks?q=` deep-links. The storyline
  pages are wiki-only, so this shouldn't hard-fail when the task DB isn't
  synced/available yet - it degrades to no cross-links (an empty map) while
  still letting genuine bugs surface.
  """
  def task_index do
    Tasks.list_tasks(preloads: [])
    |> Map.new(fn task -> {task.normalized_name, task.name} end)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error, Ecto.QueryError] -> %{}
  end

  @doc """
  Resolve the small chapter *icon* image source from the local vendored set
  (`/images/chapters/<slug>.webp`), or `nil` when there's no local icon.
  """
  def chapter_icon_src(chapter) do
    slug = Map.get(chapter, :normalized_name)

    if is_binary(slug) and local_chapter_image?(slug) do
      "/images/chapters/#{slug}.webp"
    end
  end

  defp local_chapter_image?(slug) do
    case :code.priv_dir(:eft_buddy) do
      {:error, _} ->
        false

      priv ->
        priv
        |> Path.join("static/images/chapters/#{slug}.webp")
        |> File.exists?()
    end
  end

  @doc """
  Render one parsed content section as a panel: its heading followed by its
  ordered blocks (prose, nested step lists, related-item tables, galleries).
  """
  attr :section, :map, required: true
  attr :item_index, :map, default: %{}

  def content_section(assigns) do
    assigns = assign(assigns, :endings, Map.get(assigns.section, :endings, []))

    ~H"""
    <section id={@section.dom_id} class="hud-panel p-5 space-y-4">
      <h2 class={section_heading_class(@section.level)}>{@section.heading}</h2>
      <.ending_badges :if={@endings != []} endings={@endings} />
      <.section_blocks section={@section} item_index={@item_index} />
    </section>
    """
  end

  @doc """
  A row of ending badges — the wiki's own icons, naming every ending an
  objective block leads to.
  """
  attr :endings, :list, required: true

  def ending_badges(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <span
        :for={ending <- @endings}
        class="inline-flex items-center gap-1.5 pl-1 pr-2 py-1 bg-ink-900 border border-line t-label text-[9px] text-fog-400"
      >
        <img
          :if={ending.file && ending.file["url"]}
          src={ending.file["url"]}
          alt=""
          loading="lazy"
          class="w-5 h-5 object-contain shrink-0"
        />
        {ending.label}
      </span>
    </div>
    """
  end

  @doc """
  Render one section's ordered blocks, without the panel or heading around
  them - so a variant panel can host a section's content under its own tab
  bar rather than repeating the heading the tab already carries.
  """
  attr :section, :map, required: true
  attr :item_index, :map, default: %{}

  def section_blocks(assigns) do
    ~H"""
    <%= for {block, block_idx} <- Enum.with_index(@section.blocks) do %>
      <p :if={block.kind == :heading} class={guide_heading_class(block.level)}>{block.text}</p>

      <p :if={block.kind == :prose} class={prose_class(block)}>
        {block.text}
      </p>

      <ul :if={block.kind == :list} class="space-y-1.5">
        <li
          :for={item <- block.items}
          class="flex gap-2 text-sm text-fog-300 leading-relaxed"
          style={"padding-left: #{list_indent(item.level)}rem"}
        >
          <span class="text-amber select-none shrink-0">&bull;</span>
          <span class="break-words min-w-0">{item.text}</span>
        </li>
      </ul>

      <div :if={block.kind == :items} class="hud-inset p-4">
        <.chapter_items items={block.items} item_index={@item_index} title="Related items" />
      </div>

      <div :if={block.kind == :gallery} class="flex flex-wrap gap-3">
        <.zoomable_image
          :for={{img, img_idx} <- Enum.with_index(block.images)}
          id={"lightbox-#{@section.dom_id}-#{block_idx}-#{img_idx}"}
          src={img.file["url"] || ""}
          alt={img.caption || ""}
          caption={img.caption}
          width={img.file["width"]}
          height={img.file["height"]}
        />
      </div>
    <% end %>
    """
  end

  @doc """
  One tab per ending, wearing that ending's own wiki icon.

  Deliberately the same pill the `ending_badges/1` row uses - icon, name,
  solid panel, hairline border - because they are the same four things
  named twice on the same site, and a reader who learned the badges should
  recognise these on sight. Only the states differ: a tab is a control, so
  it takes the amber treatment when it is the one you are on and lifts on
  hover.

  Links rather than click events, because which ending you are pursuing is
  the whole state of the page - worth a shareable, refresh-safe `?ending=`
  the way every other page-level tab on the site is.
  """
  attr :views, :list, required: true
  attr :active, :string, default: nil
  attr :href_for, :any, required: true
  attr :class, :any, default: nil

  def ending_tabs(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-2", @class]}>
      <.link
        :for={view <- @views}
        patch={@href_for.(view)}
        aria-current={if view.slug == @active, do: "page", else: "false"}
        class={ending_tab_class(view.slug == @active)}
      >
        <img
          :if={view.icon && view.icon["url"]}
          src={view.icon["url"]}
          alt=""
          loading="lazy"
          class="w-7 h-7 object-contain shrink-0"
        />
        <span class="whitespace-nowrap">{view.label}</span>
      </.link>
    </div>
    """
  end

  # The pill from `ending_badges/1`, one size up and given control states:
  # solid `bg-ink-900` rather than transparent, so the row reads as a set of
  # objects you can press rather than as text with outlines round it.
  defp ending_tab_class(active?) do
    [
      "t-label text-[10px] inline-flex items-center gap-2 pl-1.5 pr-3 py-1.5",
      "bg-ink-900 border transition-colors hud-focus",
      if(active?,
        do: "text-amber border-amber",
        else: "text-fog-400 border-line hover:text-fog-100 hover:border-fog-500"
      )
    ]
  end

  @doc """
  Render a list of chapter "Related Quest Items" entries. Real items render as
  tier-coloured tiles linking into the Items tab; non-item wiki concept links
  render as plain text.
  """
  attr :items, :list, required: true
  attr :item_index, :map, default: %{}
  attr :title, :string, default: nil

  def chapter_items(assigns) do
    ~H"""
    <div class="space-y-3">
      <h4 :if={@title} class="t-label text-[10px] text-amber">{@title}</h4>

      <ul class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2">
        <li :for={item <- @items} class="flex items-center gap-2 min-w-0">
          <%= case Map.get(@item_index, item.page) do %>
            <% nil -> %>
              <span class="text-sm text-fog-300 truncate" title={item.name}>{item.name}</span>
            <% db -> %>
              <.link
                navigate={~p"/items?#{[q: item.page]}"}
                class="group flex items-center gap-2 min-w-0"
                title={item.name}
              >
                <.item_tile item={db} size="w-8 h-8" link={false} />
                <span class="text-sm text-amber group-hover:underline truncate">{item.name}</span>
              </.link>
          <% end %>

          <span
            :if={item.amount && item.amount not in ["1", "0"]}
            class="text-xs text-fog-500 shrink-0"
          >
            ×{item.amount}
          </span>

          <.badge
            :if={item.found_in_raid}
            variant={:amber}
            class="shrink-0"
            title="Must be found in raid"
          >
            FiR
          </.badge>
          <.badge :if={optional_item?(item)} variant={:neutral} class="shrink-0">Optional</.badge>
        </li>
      </ul>
    </div>
    """
  end

  defp optional_item?(%{requirement: req}) when is_binary(req),
    do: String.downcase(req) == "optional"

  defp optional_item?(_), do: false

  # A paragraph the wiki bolded end to end introduces the steps under it
  # ("If the Armored case was given to Prapor in Falling Skies"), so it
  # reads brighter and heavier than the body text it governs - but stays a
  # sentence, not an uppercase label.
  defp prose_class(%{emphasis: true}),
    do: "text-sm font-semibold text-fog-100 leading-relaxed break-words"

  defp prose_class(_block), do: "text-sm text-fog-300 leading-relaxed break-words"

  @doc "Classes for a section's own heading, sized by its wiki level."
  def section_heading_class(level) when level <= 2,
    do: "t-head text-xl text-fog-100 border-b border-line pb-2 scroll-mt-24"

  def section_heading_class(level), do: guide_heading_class(level) <> " scroll-mt-24"

  @doc "Left indent (rem) for a nested list item, by its marker depth."
  def list_indent(level) when is_integer(level) and level > 1, do: (level - 1) * 1.25
  def list_indent(_), do: 0.0
end
