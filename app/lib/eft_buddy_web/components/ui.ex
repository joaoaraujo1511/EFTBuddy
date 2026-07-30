defmodule EftBuddyWeb.UI do
  @moduledoc """
  The OPERATOR HUD design-system component library.

  A fresh, Tarkov-themed set of building blocks shared by every LiveView:
  panels, stencil eyebrows, status badges, stat readouts, the deployment-strip
  tab bar, filter chips, search fields and empty states. Styling is driven
  entirely by the tokens declared in `assets/css/app.css` (no daisyUI).

  Imported globally via `EftBuddyWeb.html_helpers/0`, so `<.panel>`,
  `<.tabs>`, `<.badge>`, etc. are available in every template.
  """
  use Phoenix.Component

  import EftBuddyWeb.CoreComponents, only: [icon: 1]

  # ── Page scaffolding ───────────────────────────────────────────────

  @doc """
  Standard page header: a big condensed title, an optional subtitle, and an
  optional `:actions` slot pinned to the right.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  slot :actions

  def page_head(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-end justify-between gap-4", @class]}>
      <div class="min-w-0">
        <h1 class="t-head text-3xl sm:text-4xl text-fog-100">{@title}</h1>
        <%!-- Reserve a consistent two-line height for the subtitle on
             desktop (clamping longer copy, padding shorter copy) so the
             controls/search bar below lands at the exact same vertical
             position on every page. --%>
        <p
          :if={@subtitle}
          class="mt-2 text-sm text-fog-400 max-w-2xl leading-relaxed lg:line-clamp-2 lg:min-h-[2.85rem]"
        >
          {@subtitle}
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2 shrink-0">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "A thin stencil section eyebrow with an amber tick + trailing rule."
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def eyebrow(assigns) do
    ~H"""
    <div class={["flex items-center gap-3", @class]}>
      <span class="t-label text-[11px] text-amber shrink-0">{render_slot(@inner_block)}</span>
      <span class="h-px flex-1 hud-rule"></span>
    </div>
    """
  end

  @doc """
  Standardised filter/search control bar shared by every browse page.

  Lays out an optional tab strip on the left (filling the row) and an optional
  search field on the right at a consistent width, stacking on narrow screens.
  An optional `:filters` slot renders a secondary chip row beneath. Using this
  on every tab keeps the "options + search" area visually identical app-wide.

  Slots:
    * `:tabs`    - the `<.tabs>` strip (optional)
    * `:search`  - the `<.search>` field (optional; pass it `class="w-full"`)
    * `:filters` - a secondary `<.chips>` row (optional)
  """
  attr :class, :any, default: nil
  slot :tabs
  slot :search
  slot :filters

  def controls(assigns) do
    ~H"""
    <div class={["space-y-3", @class]}>
      <%!-- Left-aligned, content-sized tab bar; page filters sit right below. --%>
      <div :if={@tabs != []} class="flex">{render_slot(@tabs)}</div>
      <div :if={@search != []} class="flex">{render_slot(@search)}</div>
      <div :if={@filters != []}>{render_slot(@filters)}</div>
    </div>
    """
  end

  # ── Panel ──────────────────────────────────────────────────────────

  @doc """
  A tactical panel surface. Optional `title`/`eyebrow` render a header row;
  pass `notch` for the cut-corner HUD silhouette.
  """
  attr :title, :string, default: nil
  attr :eyebrow, :string, default: nil
  attr :notch, :boolean, default: false
  attr :padded, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :header
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["hud-panel", @notch && "hud-notch", @class]} {@rest}>
      <div
        :if={@title || @eyebrow || @header != []}
        class="flex items-center justify-between gap-3 px-4 py-3 border-b border-line"
      >
        <div class="min-w-0">
          <div :if={@eyebrow} class="t-label text-[10px] text-amber">{@eyebrow}</div>
          <h2 :if={@title} class="t-head text-lg text-fog-100 truncate">{@title}</h2>
        </div>
        <div :if={@header != []} class="shrink-0">{render_slot(@header)}</div>
      </div>
      <div class={[@padded && "p-4"]}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  # ── Badges & tags ──────────────────────────────────────────────────

  @doc """
  Status badge. `variant` maps to a semantic token:
  `:amber` (primary), `:go` (green/available), `:warn` (amber/WIP),
  `:rust` (red/locked-blocking), `:signal` (the secondary blue accent),
  `:olive`, `:purple` (Kappa), `:neutral` (grey).
  """
  attr :variant, :atom,
    default: :neutral,
    values: [:amber, :go, :warn, :rust, :signal, :olive, :purple, :neutral]

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "t-label text-[10px] px-2 py-1 border inline-flex items-center gap-1.5",
        badge_variant(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_variant(:amber), do: "text-amber border-amber/40 bg-amber/10"
  defp badge_variant(:go), do: "text-go border-go/40 bg-go/10"
  defp badge_variant(:warn), do: "text-warn border-warn/40 bg-warn/10"
  defp badge_variant(:rust), do: "text-rust border-rust/40 bg-rust/10"
  defp badge_variant(:signal), do: "text-signal border-signal/40 bg-signal/10"
  defp badge_variant(:olive), do: "text-olive-bright border-olive/40 bg-olive/10"
  defp badge_variant(:purple), do: "text-purple border-purple/40 bg-purple/10"
  defp badge_variant(:neutral), do: "text-fog-400 border-line-strong bg-ink-900"

  @doc """
  A small count pill (used on nav/tab/chip labels). `tone` tints it with a
  semantic colour so the little number badges read as intentional rather than
  dead grey.
  """
  attr :count, :any, required: true

  attr :tone, :atom,
    default: :neutral,
    values: [:neutral, :amber, :go, :warn, :rust, :signal, :olive, :purple]

  attr :class, :any, default: nil

  def count_pill(assigns) do
    ~H"""
    <span
      :if={is_integer(@count)}
      class={[
        "t-num text-[10px] px-1.5 py-0.5 rounded-sm border inline-block text-center min-w-[1.5rem]",
        pill_tone(@tone),
        @class
      ]}
    >
      {@count}
    </span>
    """
  end

  defp pill_tone(:amber), do: "bg-amber/15 text-amber border-amber/40"
  defp pill_tone(:go), do: "bg-go/15 text-go border-go/40"
  defp pill_tone(:warn), do: "bg-warn/15 text-warn border-warn/40"
  defp pill_tone(:rust), do: "bg-rust/15 text-rust border-rust/40"
  defp pill_tone(:signal), do: "bg-signal/15 text-signal border-signal/40"
  defp pill_tone(:olive), do: "bg-olive/15 text-olive-bright border-olive/40"
  defp pill_tone(:purple), do: "bg-purple/15 text-purple border-purple/40"
  defp pill_tone(_), do: "bg-ink-950 text-fog-400 border-line-strong"

  @doc """
  Sortable column header used by list/table views (Tasks, Items).

  Clicking emits `@event` (default `"toggle_sort"`) with `phx-value-col={@col}`;
  the parent LiveView cycles the sort and passes the resulting `@sort` back in.
  When this column is the active sort it shows an up or down chevron (matching
  `@asc` / `@desc`); otherwise it shows a faint up-down affordance. All three
  glyphs render at the same `w-3 h-3` size and inherit the button's colour, so
  the active and idle indicators are visually identical in size.
  """
  attr :label, :string, required: true
  attr :col, :string, required: true
  attr :sort, :atom, required: true
  attr :asc, :atom, required: true
  attr :desc, :atom, required: true
  attr :event, :string, default: "toggle_sort"
  attr :align, :string, default: "left"
  attr :class, :any, default: nil
  # Extra bindings (e.g. `phx-value-caliber`) so a caller can scope the
  # sort event to a sub-group — used by the per-caliber ammo blocks.
  attr :rest, :global

  def sort_header(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-col={@col}
      {@rest}
      aria-label={"Sort by #{String.downcase(@label)}"}
      title={"Sort by #{String.downcase(@label)}"}
      class={[
        "inline-flex items-center gap-1 t-label text-[9px] transition-colors hud-focus",
        (@align == "right" && "justify-end text-right") || "text-left",
        (@sort in [@asc, @desc] && "text-amber") || "text-fog-500 hover:text-fog-100",
        @class
      ]}
    >
      {@label}
      <.icon :if={@sort == @asc} name="hero-chevron-up" class="w-3 h-3" />
      <.icon :if={@sort == @desc} name="hero-chevron-down" class="w-3 h-3" />
      <.icon :if={@sort not in [@asc, @desc]} name="hero-chevron-up-down" class="w-3 h-3" />
    </button>
    """
  end

  @doc """
  Advances the 3-state sort cycle that pairs with `sort_header/1`.

  Sort state is an atom following the `:<col>_asc` / `:<col>_desc` convention,
  or `:default` for the unsorted state (where every `sort_header` shows its
  faint up-down affordance). Clicking the active column cycles ascending →
  descending → default; clicking any other column jumps straight to that
  column ascending. The caller's data layer decides what each atom (including
  `:default`) actually orders by.

  Together with `sort_header/1` this is a drop-in, reusable sort control:

      def handle_event("toggle_sort", %{"col" => col}, socket) do
        {:noreply, socket |> assign(:sort, UI.next_sort(col, socket.assigns.sort)) |> reload()}
      end
  """
  def next_sort(col, current) when is_binary(col) do
    asc = sort_atom(col, "asc")
    desc = sort_atom(col, "desc")

    cond do
      current == asc -> desc
      current == desc -> :default
      true -> asc
    end
  end

  # Resolve `:<col>_<dir>` to an existing atom (the caller's sort clauses
  # already define them). Falls back to `:default` for an unknown column so a
  # stray event can never crash or mint arbitrary atoms.
  defp sort_atom(col, dir) do
    String.to_existing_atom("#{col}_#{dir}")
  rescue
    ArgumentError -> :default
  end

  # Resolve a pill's tone from an item map: an explicit `:tone` wins; otherwise
  # an active item gets the brand amber and an inactive one stays neutral.
  defp item_pill_tone(item, active?) do
    Map.get(item, :tone) || if active?, do: :amber, else: :neutral
  end

  # ── Stat readout ───────────────────────────────────────────────────

  @doc "A labelled numeric/text readout (label above, value below)."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :boolean, default: false
  attr :class, :any, default: nil

  def stat(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <div class="t-label text-[9px] text-fog-500">{@label}</div>
      <div class={[
        "t-num text-base mt-0.5 truncate",
        if(@accent, do: "text-amber", else: "text-fog-100")
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  # ── Tab bar (deployment strip) ─────────────────────────────────────

  @doc """
  Horizontal tactical tab strip. Each item is a map with:
    * `:label` (required)
    * `:icon` (optional heroicon name)
    * `:patch` (URL → `<.link patch>`) or `:event` (`phx-click` event name)
    * `:value` / `:filter` - compared against `@active` (defaults to lowercased label)
    * `:count` - optional integer badge
  """
  attr :items, :list, required: true
  attr :active, :any, default: nil
  attr :class, :any, default: nil

  def tabs(assigns) do
    ~H"""
    <%!-- Content-sized (w-auto) so the bar hugs its tabs and stays centered by
         the parent instead of stretching full-width with dead space; scrolls
         horizontally only when the tabs overflow the available width. --%>
    <div class={[
      "flex items-stretch overflow-x-auto hud-panel border-line w-auto max-w-full",
      @class
    ]}>
      <.tab_item :for={item <- @items} item={item} active={@active} />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :active, :any, default: nil

  defp tab_item(assigns) do
    value =
      Map.get(assigns.item, :value) || Map.get(assigns.item, :filter) ||
        String.downcase(assigns.item.label)

    active? = assigns.active != nil and to_string(assigns.active) == to_string(value)
    assigns = assign(assigns, active?: active?, value: value)

    ~H"""
    <%= if patch = Map.get(@item, :patch) do %>
      <.link
        patch={patch}
        aria-current={if @active?, do: "page", else: "false"}
        class={tab_classes(@active?)}
      >
        <.icon :if={Map.get(@item, :icon)} name={@item.icon} class="w-4 h-4 shrink-0" />
        <span class={["whitespace-nowrap", tone_text(Map.get(@item, :label_tone))]}>
          {@item.label}
        </span>
        <.count_pill
          :if={Map.get(@item, :count)}
          count={@item.count}
          tone={item_pill_tone(@item, @active?)}
        />
      </.link>
    <% else %>
      <button
        type="button"
        phx-click={Map.get(@item, :event)}
        phx-value-filter={@value}
        aria-pressed={@active?}
        class={tab_classes(@active?)}
      >
        <.icon :if={Map.get(@item, :icon)} name={@item.icon} class="w-4 h-4 shrink-0" />
        <span class={["whitespace-nowrap", tone_text(Map.get(@item, :label_tone))]}>
          {@item.label}
        </span>
        <.count_pill
          :if={Map.get(@item, :count)}
          count={@item.count}
          tone={item_pill_tone(@item, @active?)}
        />
      </button>
    <% end %>
    """
  end

  defp tab_classes(active?) do
    [
      "t-label text-xs inline-flex items-center justify-center gap-2 px-4 sm:px-5 py-3 shrink-0 transition-colors border-b-2 hud-focus",
      if(active?,
        do: "text-amber border-amber bg-amber/5",
        else: "text-fog-500 border-transparent hover:text-fog-100 hover:bg-ink-800"
      )
    ]
  end

  # Maps a semantic tone to a text-colour utility (used to tint specific tab
  # labels, e.g. the Kappa/Lightkeeper questlines, to match their count pill).
  defp tone_text(:amber), do: "text-amber"
  defp tone_text(:go), do: "text-go"
  defp tone_text(:warn), do: "text-warn"
  defp tone_text(:rust), do: "text-rust"
  defp tone_text(:signal), do: "text-signal"
  defp tone_text(:olive), do: "text-olive-bright"
  defp tone_text(:purple), do: "text-purple"
  defp tone_text(_), do: nil

  # ── Filter chips ───────────────────────────────────────────────────

  @doc """
  A wrapped row of pill filter chips. Item maps: `:label`, `:value`,
  `:patch` or `:event`, optional `:phx_value` (map) and `:count`.
  """
  attr :items, :list, required: true
  attr :active, :any, default: nil
  attr :class, :any, default: nil

  def chips(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-2", @class]}>
      <.chip :for={item <- @items} item={item} active={@active} />
    </div>
    """
  end

  attr :item, :map, required: true
  attr :active, :any, default: nil

  defp chip(assigns) do
    value = Map.get(assigns.item, :value, assigns.item.label)
    active? = assigns.active != nil and to_string(assigns.active) == to_string(value)
    assigns = assign(assigns, active?: active?, value: value)

    ~H"""
    <%= if patch = Map.get(@item, :patch) do %>
      <.link
        patch={patch}
        aria-current={if @active?, do: "true", else: "false"}
        class={chip_classes(@active?)}
      >
        {@item.label}
      </.link>
    <% else %>
      <button
        type="button"
        phx-click={Map.get(@item, :event)}
        {chip_phx_value(@item, @value)}
        aria-pressed={@active?}
        class={chip_classes(@active?)}
      >
        {@item.label}
      </button>
    <% end %>
    """
  end

  defp chip_phx_value(item, value) do
    case Map.get(item, :phx_value) do
      nil -> %{"phx-value-value" => value}
      map when is_map(map) -> Map.new(map, fn {k, v} -> {"phx-value-#{k}", v} end)
    end
  end

  defp chip_classes(active?) do
    [
      "t-label text-[11px] inline-flex items-center gap-1.5 px-3 py-1.5 border transition-colors whitespace-nowrap hud-focus",
      if(active?,
        do: "bg-amber/15 text-amber border-amber",
        else: "bg-ink-850 text-fog-500 border-line hover:text-fog-100 hover:border-line-strong"
      )
    ]
  end

  # ── Search field ───────────────────────────────────────────────────

  @doc """
  Themed search box. Fires `phx-change`/`phx-submit` with the configured
  `event` (default `"search"`) and an input named `query`; the clear button
  fires `clear_event` (default `"clear_search"`).
  """
  attr :id, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, default: "Search..."
  attr :event, :string, default: "search"
  attr :clear_event, :string, default: "clear_search"
  attr :class, :any, default: nil

  def search(assigns) do
    ~H"""
    <form
      id={@id}
      role="search"
      phx-change={@event}
      phx-submit={@event}
      class={["relative", @class]}
    >
      <.icon
        name="hero-magnifying-glass"
        class="w-4 h-4 text-fog-600 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none"
      />
      <input
        type="text"
        name="query"
        value={@value}
        placeholder={@placeholder}
        aria-label={@placeholder}
        autocomplete="off"
        phx-debounce="200"
        data-search-input
        class="hud-inset w-full pl-9 pr-9 py-2.5 text-sm text-fog-100 placeholder-fog-600 hud-focus rounded-sm"
      />
      <button
        :if={@value != ""}
        type="button"
        phx-click={@clear_event}
        aria-label="Clear search"
        class="absolute right-2.5 top-1/2 -translate-y-1/2 text-fog-600 hover:text-amber transition-colors"
      >
        <.icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </form>
    """
  end

  # ── Buttons / links ────────────────────────────────────────────────

  @doc "A HUD action button/link (variant `:solid` amber or `:ghost`)."
  attr :variant, :atom, default: :ghost, values: [:solid, :ghost]
  attr :icon, :string, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(href navigate patch type phx-click phx-value-id disabled name value form)

  slot :inner_block, required: true

  def action(%{rest: rest} = assigns) do
    classes = [
      "t-label text-xs inline-flex items-center justify-center gap-2 px-4 py-2.5 border transition-colors hud-focus",
      action_variant(assigns.variant),
      assigns.class
    ]

    assigns = assign(assigns, :classes, classes)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        <.icon :if={@icon} name={@icon} class="w-4 h-4" />
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>
        <.icon :if={@icon} name={@icon} class="w-4 h-4" />
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp action_variant(:solid),
    do:
      "bg-amber text-ink-950 border-amber hover:bg-amber-bright hover:border-amber-bright font-bold"

  defp action_variant(:ghost),
    do: "bg-ink-850 text-fog-300 border-line hover:text-amber hover:border-amber/60"

  # ── Empty state ────────────────────────────────────────────────────

  @doc "A centered empty/zero-results state."
  attr :icon, :string, default: "hero-no-symbol"
  attr :title, :string, default: "No results"
  attr :message, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block

  def empty(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center text-center py-16 px-6", @class]}>
      <div class="w-14 h-14 hud-notch hud-panel flex items-center justify-center mb-4">
        <.icon name={@icon} class="w-6 h-6 text-fog-600" />
      </div>
      <p class="t-head text-lg text-fog-200">{@title}</p>
      <p :if={@message} class="mt-1.5 text-sm text-fog-500 max-w-sm">{@message}</p>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Shared "your watchlist is empty" state.

  Every browse page with a Watchlist tab (Tasks, Events, Items, Flea Market)
  renders the exact same zero-state when the operator hasn't bookmarked
  anything, so it lives here as one component instead of being copy-pasted per
  page. The optional `noun` tailors the copy to the page (e.g. "quest",
  "event"); it defaults to a page-agnostic "entry".
  """
  attr :noun, :string, default: "entry"
  attr :class, :any, default: nil

  def watchlist_empty(assigns) do
    ~H"""
    <.empty
      class={@class}
      icon="hero-bookmark"
      title="Your watchlist is empty"
      message={"Bookmark any #{@noun} to pin it here. Bookmarked #{@noun}s also jump to the top of the list."}
    />
    """
  end

  @doc """
  Shared "no results" state for a search / filter / category combination
  that matches nothing.

  Every browse page (Tasks, Items, Flea, Ammo, Events, Hideout, Maps,
  Storyline) renders the exact same zero-results state so the experience
  is consistent, instead of each page inventing its own copy/icon. The
  message is deliberately **static** — it never echoes the current query
  — so the state reads the same regardless of what was typed. `noun` is
  the plural subject, e.g. `"tasks"` renders "No tasks match".
  """
  attr :noun, :string, default: "results"
  attr :class, :any, default: nil

  def no_results(assigns) do
    ~H"""
    <.empty
      class={@class}
      icon="hero-funnel"
      title={"No #{@noun} match"}
      message="Adjust your search or filters to see more."
    />
    """
  end

  @doc """
  Consistent "data not loaded yet" panel, shared by every browse page.

  A single component drives the identical not-loaded screen on every
  browse page, in one of two states (the caller resolves which via
  `EftBuddyWeb.LoadState`):

    * `:loading` (default) - the background sync is still populating the
      page's data. Shows a spinning marker and the standby copy.
    * `:error` - the sync that feeds this page last failed, so the rows
      likely won't arrive on their own. Shows a fault marker and, when
      given a `retry_to` path, a Retry link that reloads the page (a
      plain full-page navigation, matching how the rest of the app
      navigates - so it works even while the LiveView socket is down).

  Rendered as a polite live region (`role="status"`, `aria-busy` while
  loading) so assistive tech announces the wait, and given a tall
  min-height so the marker sits centred in the content column - making
  the not-loaded screen pixel-identical from page to page. The spinner
  honours `prefers-reduced-motion` (it simply doesn't spin).
  """
  attr :state, :atom, default: :loading, values: [:loading, :error]
  attr :retry_to, :string, default: nil
  attr :class, :any, default: nil

  def standby(assigns) do
    ~H"""
    <div
      role="status"
      aria-live="polite"
      aria-busy={to_string(@state == :loading)}
      class={[
        "flex flex-col items-center justify-center text-center min-h-[50vh] py-16 px-6",
        @class
      ]}
    >
      <div class="w-14 h-14 hud-notch hud-panel flex items-center justify-center mb-4">
        <.icon
          name={if @state == :error, do: "hero-exclamation-triangle", else: "hero-arrow-path"}
          class={[
            "w-6 h-6",
            if(@state == :error, do: "text-rust", else: "text-amber motion-safe:animate-spin")
          ]}
        />
      </div>
      <p class="t-head text-lg text-fog-200">{standby_title(@state)}</p>
      <p class="mt-1.5 text-sm text-fog-500 max-w-sm">{standby_message(@state)}</p>
      <.link
        :if={@state == :error and @retry_to}
        href={@retry_to}
        class="mt-5 t-label text-xs inline-flex items-center justify-center gap-2 px-4 py-2.5 border bg-ink-850 text-fog-300 border-line hover:text-amber hover:border-amber/60 transition-colors hud-focus"
      >
        <.icon name="hero-arrow-path" class="w-4 h-4" /> Retry
      </.link>
    </div>
    """
  end

  defp standby_title(:error), do: "Sync Unavailable"
  defp standby_title(_), do: "Standby"

  defp standby_message(:error),
    do:
      "The background sync couldn't populate this page. This is usually temporary - retry in a moment."

  defp standby_message(_), do: "Data is loading in the background. Refresh shortly."

  # ── Loading sentinel for infinite scroll ───────────────────────────

  @doc "An infinite-scroll sentinel row. Renders nothing once `done?`."
  attr :done?, :boolean, default: false
  attr :event, :string, default: "load_more"

  def scroll_sentinel(assigns) do
    ~H"""
    <div
      :if={not @done?}
      phx-click={@event}
      phx-viewport-bottom={@event}
      class="py-8 flex items-center justify-center"
    >
      <span class="t-label text-[10px] text-fog-600 inline-flex items-center gap-2">
        <span class="h-1.5 w-1.5 rounded-full bg-amber hud-pulse"></span> Loading more
      </span>
    </div>
    """
  end

  # ── Item icon tile (shared across Items/Tasks/Hideout/Storyline) ───

  @doc """
  A tier-coloured item icon tile that links into the Items tab. `item` is an
  `%EftBuddy.Items.Item{}` (or any map with `name`, `image_512px_link`,
  `icon_link`, `background_color`). Optional `qty` badge and `highlight`.
  """
  attr :item, :any, required: true
  attr :qty, :any, default: nil
  attr :size, :string, default: "w-16 h-16"
  attr :highlight, :boolean, default: false
  attr :link, :boolean, default: true

  def item_tile(assigns) do
    # Tier background is set via a `.item-bg-*` utility class (mapped from the
    # tarkov.dev `backgroundColor` token) rather than an inline `style`, so the
    # tile carries no per-item inline styling.
    assigns =
      assign(
        assigns,
        :bg_class,
        EftBuddy.Items.BackgroundColor.class(
          assigns.item && Map.get(assigns.item, :background_color)
        )
      )

    ~H"""
    <%= if @link and @item do %>
      <.link
        navigate={"/items?q=" <> URI.encode(@item.name)}
        class={[
          "relative flex items-center justify-center overflow-hidden shrink-0 border transition-colors hover:border-amber",
          @size,
          @bg_class,
          if(@highlight, do: "border-amber", else: "border-line")
        ]}
        title={@item.name}
      >
        {item_tile_inner(assigns)}
      </.link>
    <% else %>
      <span
        class={[
          "relative flex items-center justify-center overflow-hidden shrink-0 border",
          @size,
          @bg_class,
          if(@highlight, do: "border-amber", else: "border-line")
        ]}
        title={@item && @item.name}
      >
        {item_tile_inner(assigns)}
      </span>
    <% end %>
    """
  end

  defp item_tile_inner(assigns) do
    ~H"""
    <%= if @item && (Map.get(@item, :image_512px_link) || Map.get(@item, :icon_link)) do %>
      <%!-- Remote CDN artwork (tarkov.dev). `img-fallback` hands off to the
           inline glyph below via the CSP-safe error listener in app.js when
           the image 404s or the CDN throttles a burst of requests (e.g. after
           a full-page reload), so a failed thumbnail degrades to the cube
           placeholder instead of the browser's broken-image icon. --%>
      <img
        src={Map.get(@item, :image_512px_link) || Map.get(@item, :icon_link)}
        alt={@item.name}
        loading="lazy"
        decoding="async"
        class="img-fallback w-full h-full object-contain"
      />
      <span style="display:none;" class="absolute inset-0" aria-hidden="true">
        <span class="absolute inset-0 flex items-center justify-center">
          <.icon name="hero-cube" class="w-5 h-5 text-line-strong" />
        </span>
      </span>
    <% else %>
      <.icon name="hero-cube" class="w-5 h-5 text-line-strong" />
    <% end %>
    <span
      :if={@qty}
      class="absolute top-0 right-0 t-num text-[10px] text-fog-100 bg-ink-900/90 border-l border-b border-line px-1 leading-tight"
    >
      ×{@qty}
    </span>
    """
  end

  # ── Price-history sparkline ────────────────────────────────────────

  @doc """
  A compact inline price-history graph rendered straight from an item's
  `historical_prices` - the ~2-day flea time series from tarkov.dev
  (`%{"price" => int, "timestamp" => int_ms}` points, oldest first).

  Draws a single `<polyline>` in a fixed 100×28 viewBox stretched to the
  container width (`class`), tinted by the 48h `tone` (`:up` = go,
  `:down` = rust, `:flat`/other = fog). Renders nothing when there are
  fewer than two numeric points to plot, so callers can drop it in
  unconditionally and items with no history simply show no graph.

  Shared by the Flea Market cards and the Items detail panel.
  """
  attr :points, :any, default: nil
  attr :tone, :atom, default: :flat
  attr :class, :any, default: "w-full h-7"

  def price_sparkline(assigns) do
    assigns = assign(assigns, :poly, spark_polyline(assigns.points))

    ~H"""
    <svg
      :if={@poly}
      viewBox="0 0 100 28"
      preserveAspectRatio="none"
      class={[
        @class,
        @tone == :up && "text-go",
        @tone == :down && "text-rust",
        @tone not in [:up, :down] && "text-fog-500"
      ]}
      aria-hidden="true"
    >
      <polyline
        points={@poly}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  @spark_w 100
  @spark_h 28
  @spark_pad 2

  # Build the `points` attribute for the polyline: index → x across the
  # 100-wide viewBox, price → (inverted) y in the 28-high range with a 2px
  # vertical pad so the line never clips. `nil` for < 2 numeric prices.
  defp spark_polyline(points) when is_list(points) do
    prices = points |> Enum.map(&Map.get(&1, "price")) |> Enum.filter(&is_number/1)

    case prices do
      [] -> nil
      [_only] -> nil
      _ -> build_spark_polyline(prices)
    end
  end

  defp spark_polyline(_), do: nil

  defp build_spark_polyline(prices) do
    min = Enum.min(prices)
    max = Enum.max(prices)
    span = Kernel.max(max - min, 1)
    n = length(prices)
    inner_h = @spark_h - 2 * @spark_pad

    prices
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {price, i} ->
      x = i * @spark_w / (n - 1)
      y = @spark_pad + inner_h * (1 - (price - min) / span)
      "#{spark_coord(x)},#{spark_coord(y)}"
    end)
  end

  defp spark_coord(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
end
