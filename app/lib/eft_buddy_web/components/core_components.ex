defmodule EftBuddyWeb.CoreComponents do
  @moduledoc """
  Foundational UI primitives for the OPERATOR HUD frontend: flash notices,
  form inputs, the heroicon bridge, and a wiki/screenshot lightbox. Styling
  is driven by the design tokens in `assets/css/app.css` (no daisyUI). Higher
  level building blocks live in `EftBuddyWeb.UI`.
  """
  use Phoenix.Component
  use Gettext, backend: EftBuddyWeb.Gettext

  alias EftBuddy.{Attribution, Credits}
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices as a corner toast.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-20 right-4 z-[60] w-80 sm:w-96 max-w-[calc(100vw-2rem)]"
      {@rest}
    >
      <div class={[
        "hud-panel hud-notch border-l-4 px-4 py-3 flex items-start gap-3 shadow-xl",
        @kind == :info && "border-l-signal",
        @kind == :error && "border-l-rust"
      ]}>
        <.icon
          :if={@kind == :info}
          name="hero-information-circle"
          class="size-5 shrink-0 text-signal mt-0.5"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-triangle"
          class="size-5 shrink-0 text-rust mt-0.5"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="t-label text-[11px] text-fog-100">{@title}</p>
          <p class="text-sm text-fog-300 break-words">{msg}</p>
        </div>
        <button
          type="button"
          class="group shrink-0 text-fog-600 hover:text-fog-100"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button or button-styled link.
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary ghost)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variant_class =
      case assigns.variant do
        "ghost" ->
          "bg-ink-850 text-fog-300 border-line hover:text-amber hover:border-amber/60"

        _ ->
          "bg-amber text-ink-950 border-amber hover:bg-amber-bright hover:border-amber-bright font-bold"
      end

    assigns =
      assign(assigns, :class, [
        "t-label text-xs inline-flex items-center justify-center gap-2 px-4 py-2.5 border transition-colors hud-focus disabled:opacity-40 disabled:cursor-not-allowed",
        variant_class,
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages. Supports a
  `Phoenix.HTML.FormField` or explicit attributes.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step phx-debounce)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} class="t-label text-[10px] text-fog-500 block mb-1.5">{@label}</label>
      <select
        id={@id}
        name={@name}
        class={[@class || base_input_class(@errors), "appearance-none"]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} class="t-label text-[10px] text-fog-500 block mb-1.5">{@label}</label>
      <textarea id={@id} name={@name} class={[@class || base_input_class(@errors)]} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label :if={@label} class="t-label text-[10px] text-fog-500 block mb-1.5">{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@class || base_input_class(@errors)]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp base_input_class(errors) do
    [
      "hud-inset w-full px-3 py-2.5 text-sm text-fog-100 placeholder-fog-600 rounded-sm hud-focus",
      errors == [] && "focus:border-amber",
      errors != [] && "border-rust"
    ]
  end

  @doc """
  A styled on/off check control used by the trackers (Tasks, Hideout).

  Rendered as an accessible `<button>` (not a native `<input type=checkbox>`)
  so it matches the HUD styling: a small square that fills green with a check
  when on, and is dim/hollow when off. Wire it up by passing the `phx-click`
  event and any `phx-value-*` params through — they're forwarded to the
  button:

      <.check_toggle
        checked={done?}
        phx-click="toggle_complete"
        phx-value-id={id}
        label="Mark complete"
      />
  """
  attr :checked, :boolean, default: false
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)

  def check_toggle(assigns) do
    ~H"""
    <button
      type="button"
      role="checkbox"
      aria-checked={to_string(@checked)}
      aria-label={@label}
      title={@label}
      class={[
        "w-5 h-5 shrink-0 border flex items-center justify-center cursor-pointer transition-colors hud-focus",
        (@checked && "bg-go/15 border-go/50 text-go") ||
          "bg-ink-950 border-line-strong text-transparent hover:border-fog-500",
        @class
      ]}
      {@rest}
    >
      <.icon name="hero-check" class="w-3.5 h-3.5" />
    </button>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-1.5 items-center text-xs text-rust">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com) via the bundled `hero-*` class
  set. Use `-solid` / `-mini` suffixes for the other styles.
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS show / hide (used by the flash group's reconnect notices)

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-2",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0",
         "opacity-0 translate-y-2"}
    )
  end

  @doc "Translates an error message using gettext."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(EftBuddyWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(EftBuddyWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  A wiki/objective screenshot rendered as a height-capped thumbnail that
  amplifies to a full-screen lightbox (pure client-side `JS`). Shared by the
  Tasks and Storyline tabs; `id` must be unique on the page.
  """
  attr :id, :string, required: true
  attr :src, :string, required: true
  attr :alt, :string, default: ""
  attr :caption, :string, default: nil
  attr :width, :any, default: nil
  attr :height, :any, default: nil

  def zoomable_image(assigns) do
    ~H"""
    <figure class="space-y-1 max-w-full">
      <div class="group relative inline-block max-w-full">
        <img
          src={@src}
          alt={@alt}
          width={@width}
          height={@height}
          loading="lazy"
          phx-click={open_lightbox(@id)}
          class="max-w-full max-h-56 w-auto h-auto border border-line object-contain cursor-zoom-in hover:border-amber/60 transition-colors"
        />
        <button
          type="button"
          phx-click={open_lightbox(@id)}
          aria-label="Enlarge image"
          class="absolute top-2 right-2 inline-flex items-center justify-center w-7 h-7 bg-ink-950/70 text-fog-200 border border-line opacity-0 group-hover:opacity-100 focus:opacity-100 transition-opacity hover:text-amber"
        >
          <.icon name="hero-arrows-pointing-out" class="w-4 h-4" />
        </button>
      </div>

      <figcaption
        :if={@caption && @caption != ""}
        class="w-0 min-w-full text-xs text-fog-500 break-words"
      >
        {@caption}
      </figcaption>

      <div
        id={@id}
        class="hidden fixed inset-0 z-[100] items-center justify-center bg-ink-950/95 p-4"
        phx-click={close_lightbox(@id)}
        phx-window-keydown={close_lightbox(@id)}
        phx-key="escape"
      >
        <img src={@src} alt={@alt} class="max-w-full max-h-[90vh] w-auto h-auto object-contain" />
        <button
          type="button"
          phx-click={close_lightbox(@id)}
          aria-label="Shrink image"
          class="absolute top-4 right-4 inline-flex items-center justify-center w-10 h-10 bg-ink-900/80 text-fog-200 border border-line hover:text-amber"
        >
          <.icon name="hero-arrows-pointing-in" class="w-6 h-6" />
        </button>
      </div>
    </figure>
    """
  end

  defp open_lightbox(id) do
    %JS{}
    |> JS.remove_class("hidden", to: "#" <> id)
    |> JS.add_class("flex", to: "#" <> id)
  end

  defp close_lightbox(id) do
    %JS{}
    |> JS.remove_class("flex", to: "#" <> id)
    |> JS.add_class("hidden", to: "#" <> id)
  end

  @doc """
  An always-visible credit for content taken from an upstream source.

  The wiki prose we render is CC BY-NC-SA 3.0, where attribution is a
  condition of the licence rather than a courtesy — so this has to render
  next to the content itself, without the visitor having to click anything
  to reveal it. Deliberately styled as small HUD telemetry rather than a
  banner: unobtrusive is fine, hidden is not.

  Reads as one line: what the content is, who made it, and the licence. The
  creator links to the specific upstream page and the licence to its full
  text, so the line is self-contained — there is no central credits page to
  defer to, and nothing here should require a second click to be complete.

  Not wiki-specific: pass `source` to credit any `EftBuddy.Attribution`
  entry. The map viewer uses it for the vendored SVG artwork.

  Where a sync has captured them, the page's own authors sit behind a chip
  next to the line. The popup lists them and expands in place — it never
  sends the reader elsewhere to finish reading a credit. It holds the roster
  and nothing else: a link to the source page is not a sub-item of the people
  who wrote it, and burying one there made the source unreachable in practice
  on every page that has contributors.

  `href` is the specific upstream page the content came from (the
  `wiki_link` captured at scrape time). It is optional only because a
  manifest scraped before that field was persisted may not have one; the
  credit still renders, just without the deep link.

  ## The modification indication is NOT rendered here

  CC BY-NC-SA asks that adaptation be indicated. That was a line reading
  "Adapted for EFT Buddy" in the contributors popup; it was removed along with
  the duplicate source link beside it, to keep this component to one job.

  Nothing in the UI states it now — the footer carries the Battlestate and
  non-commercial statements but says nothing about adaptation, and `NOTICE` at
  the repository root covers redistribution of the source tree, not the rendered
  site.

  This is a DECISION, not an oversight: the gap was identified, costed and
  accepted by the project owner. Do not quietly re-add the line. If it is ever
  reinstated it belongs site-wide — one clause in `EftBuddyWeb.Layouts.footer/1`
  — rather than repeated beside every credit, which is what made it intrusive
  enough to remove in the first place.

  ## Examples

      <.source_credit href={@chapter.wiki_link} id="credit-chapter" contributors={@chapter.contributors} />
  """
  attr :href, :string, default: nil

  # Defaults to the broad "Content" because that is the honest answer on most
  # pages: a storyline chapter, an event, or a quest with no API row is built
  # from the wiki page end to end — objectives, banner, prose and screenshots
  # alike — not from its guide section alone. Only the API-backed quest panel,
  # where objectives and rewards come from tarkov.dev and just the write-up is
  # the wiki's, narrows this to "Guide content".
  attr :what, :string,
    default: "Content",
    doc: ~s(what was taken from the source, e.g. "Guide content")

  attr :source, :map, default: nil, doc: "an EftBuddy.Attribution entry; defaults to the wiki"
  attr :class, :any, default: nil

  attr :id, :string,
    default: nil,
    doc: "required for the contributors popup; without it only the plain line renders"

  attr :contributors, :list, default: [], doc: "named wiki contributors for this page"

  attr :image_uploaders, :list,
    default: [],
    doc: "uploaders of contributor-licensed images; folded into the contributor list"

  # A source can name the person who made *this* item as well as the project it
  # came from. The map artwork is the case: `maps.json` credits an author per
  # map (Shebuka for the SVGs, TarkovBOT.eu for Icebreaker), and the project
  # credit alone left every one of them unnamed.
  attr :author, :string,
    default: nil,
    doc: "the specific creator of this item, named ahead of the source-level credit"

  # Omitted when the author's own link is the same place `href` already points,
  # which is true of every Shebuka entry upstream — two links to one destination
  # in one credit is noise.
  attr :author_href, :string, default: nil, doc: "link for :author; omit if it duplicates :href"

  # A source's licence does not always cover everything credited to it. The tile
  # map bases carry no stated licence anywhere upstream, and asserting a grant
  # nobody made is worse than showing no licence at all — see the moduledoc of
  # `EftBuddy.Attribution`, which applies the same rule to wiki screenshots.
  attr :license, :boolean,
    default: true,
    doc: "false when the source's licence does not cover this particular item"

  def source_credit(assigns) do
    assigns =
      assigns
      |> assign(:src, assigns.source || Attribution.wiki())
      |> assign(:popup_id, assigns.id && assigns.id <> "-credits")
      # One flat list. Uploaders of contributor-licensed images are merged in
      # rather than listed under their own heading: they are credited people
      # like any other, and a second block inside one popup read as a separate
      # widget. An uploader is not necessarily a page editor, so without the
      # merge they would appear nowhere.
      |> assign(
        :preview,
        Credits.preview(Enum.uniq(assigns.contributors ++ assigns.image_uploaders))
      )
      # Gated on the merged list, so a page with an image uploader but no
      # captured contributors still opens.
      |> then(fn a ->
        assign(a, :popup?, !!(a.popup_id && a.preview.total > 0))
      end)

    ~H"""
    <div class={["relative", @class]}>
      <p class="t-label text-[9px] text-fog-600 leading-relaxed flex flex-wrap items-center gap-x-1.5 gap-y-0.5">
        <span>{@what} by</span>
        <%!-- When the item names its own author, that author leads and the
             source-level credit follows it: "by Shebuka · tarkov-dev-svg-maps
             contributors". Without one the line is unchanged - the source's
             creator is who "by" refers to. --%>
        <a
          :if={@author && @author_href}
          href={@author_href}
          target="_blank"
          rel="noopener noreferrer"
          class={credit_link_class()}
        >
          {@author}
        </a>
        <span :if={@author && is_nil(@author_href)}>{@author}</span>
        <span :if={@author} aria-hidden="true">·</span>
        <%!-- The creator carries the link to the upstream page, ALWAYS when there
             is one to carry. It used to go plain whenever the contributors popup
             existed, on the reasoning that the popup's "original page" link went
             to the same destination and two links to one place read as noise.

             That was wrong in practice: on the Tasks tab the popup is exactly
             where the link went, so the only route to the source page was to open
             a control labelled "contributors" — a link to the page the content
             came from is not a sub-item of the roster who wrote it, and nobody
             looking for the former thinks to press the latter. The popup's copy
             of the link is gone; this is the single one. --%>
        <a
          :if={@href}
          href={@href}
          target="_blank"
          rel="noopener noreferrer"
          class={credit_link_class()}
        >
          {@src.creator}
        </a>
        <span :if={is_nil(@href)}>{@src.creator}</span>
        <span :if={@license} aria-hidden="true">·</span>
        <a
          :if={@license}
          href={@src.license_url}
          target="_blank"
          rel="noopener noreferrer"
          class={credit_link_class()}
        >
          {@src.license}
        </a>
        <%!-- The chip only appears once a sync has captured contributors, so
             pages scraped before that degrade to the plain line above rather
             than showing an empty popup. --%>
        <span :if={@popup?} aria-hidden="true">·</span>
        <button
          :if={@popup?}
          type="button"
          phx-click={JS.toggle(to: "##{@popup_id}", display: "block")}
          aria-controls={@popup_id}
          class="t-label text-[9px] px-1.5 py-0.5 border border-amber/35 bg-amber/10 text-amber hover:border-amber hover:bg-amber/20 transition-colors hud-focus"
        >
          <%!-- "contributors", not "credits": this chip is specifically the
               people who wrote *this* page, as distinct from the source-level
               credit the rest of the line carries. --%>
          contributors · {@preview.total}
        </button>
      </p>

      <div
        :if={@popup?}
        id={@popup_id}
        class="hidden absolute z-50 bottom-full mb-2 left-0 w-[380px] max-w-[92vw] bg-ink-900 border border-line-strong shadow-xl"
        phx-click-away={JS.hide(to: "##{@popup_id}")}
        phx-window-keydown={JS.hide(to: "##{@popup_id}")}
        phx-key="escape"
      >
        <div class="h-px bg-amber"></div>
        <div class="p-4 space-y-2.5">
          <p class="t-label text-[9px] text-fog-600">Written by these wiki contributors</p>

          <ul class="grid grid-cols-2 gap-x-3 gap-y-1.5">
            <.contributor_item :for={name <- @preview.shown} name={name} />
          </ul>

          <%!-- The remainder is rendered up front and hidden, then revealed by a
               JS class toggle. The names are already in assigns, so expanding in
               place costs nothing and keeps the reader on the page they are
               reading — the previous version sent them to a separate roster to
               finish a credit, which is a poor thing to make someone do. --%>
          <ul
            :if={@preview.remaining > 0}
            id={@popup_id <> "-rest"}
            class="hidden grid grid-cols-2 gap-x-3 gap-y-1.5"
          >
            <.contributor_item :for={name <- @preview.rest} name={name} />
          </ul>

          <.show_all_toggle
            :if={@preview.remaining > 0}
            id={@popup_id <> "-more"}
            target={"##{@popup_id}-rest"}
            controls={@popup_id <> "-rest"}
            total={@preview.total}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :name, :string, required: true

  defp contributor_item(assigns) do
    ~H"""
    <li class="flex items-center gap-2 min-w-0">
      <.monogram name={@name} />
      <a
        href={Credits.profile_url(@name)}
        target="_blank"
        rel="noopener noreferrer"
        title={@name}
        class="text-[11px] text-fog-300 hover:text-amber underline decoration-line hover:decoration-amber/60 underline-offset-2 truncate transition-colors"
      >
        {@name}
      </a>
    </li>
    """
  end

  defp credit_link_class do
    "text-fog-500 hover:text-amber underline decoration-line hover:decoration-amber/60 underline-offset-2 transition-colors"
  end

  @doc """
  Two-way "Show all N" / "Show less" control for a list that renders a preview
  and keeps its remainder in the DOM behind a `hidden` class.

  Purely client-side: the hidden rows are already rendered, so revealing them
  is a class toggle rather than a round trip, and no expansion state has to be
  tracked server-side. That matters most on the stream-backed pages, where a
  server-held flag would mean re-rendering the whole row to reveal data the
  browser already has.

  The control is deliberately two-way. Anything a reader can open, they must be
  able to close - a one-way reveal leaves them stuck with a wall of rows and no
  way back short of collapsing the whole panel. Both labels are rendered up
  front and swapped by the same click that reveals the rows.

  `@target` is a CSS selector for what to reveal. It can match a single
  container *or* a set of rows (`"#some-list li[data-rest]"`), so a list whose
  overflow can't be wrapped in a container - because the wrapper would interfere
  with its layout - can still be targeted row by row.

  `@total` is the size of the *whole* list, not the hidden remainder - "Show all
  24" tells the reader what they'll get, which is the useful number.

  ## Examples

      <.show_all_toggle id="roster-more" target="#roster-rest" controls="roster-rest" total={24} />
  """
  attr :id, :string, required: true
  attr :target, :string, required: true, doc: "CSS selector for the hidden remainder"
  attr :total, :integer, required: true, doc: "size of the full list"

  attr :controls, :string,
    default: nil,
    doc: "id of the revealed container, when the target is a single element"

  attr :class, :any, default: nil

  def show_all_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      aria-expanded="false"
      aria-controls={@controls}
      phx-click={
        JS.toggle_class("hidden", to: @target)
        |> JS.toggle_class("hidden", to: "##{@id} [data-show-all]")
        |> JS.toggle_class("hidden", to: "##{@id} [data-show-less]")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
      }
      class={["t-label text-[9px] text-amber hover:underline hud-focus", @class]}
    >
      <span data-show-all>Show all {@total}</span>
      <span data-show-less class="hidden">Show less</span>
    </button>
    """
  end

  @doc """
  A contributor's initials on a colour derived from their name.

  Used instead of fetching Fandom avatars: half of sampled contributors share
  the platform default image, so an avatar grid would render as repeated
  clones — and mirroring them would mean holding third-party personal data
  and leaking visitor IPs to Fandom's CDN on every view. This renders
  locally, costs nothing, and gives each person a stable identity across the
  app because the colour is a pure function of the name.
  """
  attr :name, :string, required: true
  attr :class, :any, default: "w-[18px] h-[18px] text-[8px]"

  def monogram(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      title={@name}
      class={[
        "inline-flex items-center justify-center shrink-0 font-bold text-ink-950 leading-none",
        monogram_bg(Credits.color_index(@name)),
        @class
      ]}
    >
      {Credits.initials(@name)}
    </span>
    """
  end

  defp monogram_bg(0), do: "bg-amber"
  defp monogram_bg(1), do: "bg-olive-bright"
  defp monogram_bg(2), do: "bg-signal"
  defp monogram_bg(3), do: "bg-blue"
  defp monogram_bg(4), do: "bg-purple"
  defp monogram_bg(_), do: "bg-fog-400"

  @doc """
  Tailwind classes for a guide sub-heading, sized by its wiki heading level.
  Shared by the Tasks and Storyline tabs.
  """
  def guide_heading_class(3), do: "t-label text-xs text-fog-200 mt-2"
  def guide_heading_class(4), do: "text-sm font-semibold text-fog-200 mt-1"
  def guide_heading_class(5), do: "t-label text-[10px] text-fog-500 pl-2 border-l-2 border-line"
  def guide_heading_class(_), do: "text-sm font-semibold text-fog-200 mt-1"
end
