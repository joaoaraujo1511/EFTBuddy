defmodule EftBuddyWeb.Layouts do
  @moduledoc """
  Application layouts for the OPERATOR HUD frontend.

  The shell is a two-part tactical console:

    * a fixed **left navigation rail** holding the brand, the operator /
      profile block (PMC level, scav karma, game mode, faction) and the
      primary nav. It collapses to an icon-only strip on desktop (showing a
      compact level-only profile summary) and slides off-canvas on mobile; and
    * a slim, full-width **top bar** for the page title, the global search box
      and app-level actions (progress backup, report a bug).

  The **progress backup** menu (top bar) exports / imports / resets the
  per-browser state - the localStorage progress blob plus the `eft_prefs`
  cookie - as a single JSON file. Since the tracker is account-free, this is
  the only backup and cross-device path; the actions are handled entirely
  client-side by the `Backup` hook (see `assets/js/app.js`).

  The rail-collapsed state is a per-browser pref owned by the operator's
  server-side session like the rest of the operator state (see
  `EftBuddyWeb.OperatorState`), so the layout the visitor last chose is already
  correct in the first render - on a live navigation as well as on their next
  visit - with no flash of defaults.
  """
  use EftBuddyWeb, :html

  embed_templates "layouts/*"

  alias EftBuddyWeb.OperatorState

  # Rail width (expanded) and content padding must stay in lock-step so the
  # fixed rail never overlaps the content column on desktop. The top bar spans
  # full-width from the rail's right edge, so it takes a matching `left` offset.
  @rail_w "lg:pl-60"
  @rail_w_collapsed "lg:pl-[4.5rem]"
  @bar_l "lg:left-60"
  @bar_l_collapsed "lg:left-[4.5rem]"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :active, :atom, default: nil
  attr :page_title, :string, default: nil
  attr :search_query, :string, default: nil
  attr :search_placeholder, :string, default: nil
  attr :pmc_level, :integer, default: 1
  attr :mode, :atom, default: :pvp
  attr :faction, :atom, default: :usec
  attr :scav_karma, :float, default: 0.0
  attr :rail_collapsed, :boolean, default: false
  slot :inner_block, required: true

  @doc "Application shell: left nav rail + top bar + content."
  def app(assigns) do
    assigns =
      assigns
      |> assign(:content_pad_l, if(assigns.rail_collapsed, do: @rail_w_collapsed, else: @rail_w))
      |> assign(:bar_left, if(assigns.rail_collapsed, do: @bar_l_collapsed, else: @bar_l))

    ~H"""
    <.flash_group flash={@flash} />
    <%!-- Per-browser persistence bridge (cookie prefs + localStorage progress);
         present on every page so the Hud hook is always mounted. --%>
    <div id="hud-store" phx-hook="Hud" hidden></div>

    <div id="app-shell" phx-hook="Shell" class="min-h-screen">
      {left_rail(assigns)}
      {top_bar(assigns)}

      <div class={[
        "min-h-screen flex flex-col pt-14",
        @content_pad_l
      ]}>
        <main class="flex-1">
          {render_slot(@inner_block)}
        </main>

        {footer(assigns)}
      </div>

      <%!-- Mobile rail scrim, toggled client-side by the Shell hook (the mobile
           rail is ephemeral, client-only state). --%>
      <div
        data-shell-backdrop
        class="hidden fixed inset-0 z-30 bg-black/60 lg:hidden"
        aria-hidden="true"
      >
      </div>
    </div>
    """
  end

  # ── Left navigation rail ───────────────────────────────────────────

  defp left_rail(assigns) do
    ~H"""
    <aside
      id="left-rail"
      data-shell-rail
      aria-label="Primary navigation"
      class={[
        "fixed top-0 left-0 bottom-0 z-40 flex flex-col bg-ink-900 border-r border-line",
        "transition-transform duration-200 ease-out -translate-x-full lg:translate-x-0",
        if(@rail_collapsed, do: "w-60 lg:w-[4.5rem]", else: "w-60")
      ]}
    >
      <%!-- amber tracer along the inner edge (matches the top bar's rule) --%>
      <div class="absolute top-0 right-0 bottom-0 w-px hud-rule-v opacity-60"></div>

      <%!-- brand, centered in the rail header (collapse toggle lives in the top bar) --%>
      <div class="relative h-14 flex items-center justify-center px-3 shrink-0">
        <.link navigate={~p"/"} class="flex items-center min-w-0 group">
          <span class="t-head text-xl text-fog-100 group-hover:text-amber transition-colors whitespace-nowrap">
            EFT<span class="text-amber">//</span>
            <span class={[
              if(@rail_collapsed, do: "lg:hidden", else: "")
            ]}>
              BUDDY
            </span>
          </span>
        </.link>

        <%!-- mobile close --%>
        <button
          type="button"
          data-shell-rail-close
          aria-label="Close navigation"
          class="absolute right-2 lg:hidden w-8 h-8 flex items-center justify-center border border-line text-fog-400 hover:text-amber transition-colors hud-focus"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <div class="flex-1 overflow-y-auto overflow-x-hidden no-scrollbar">
        <%!-- Operator / profile block. Full controls when the rail is expanded;
             hidden (in favour of the compact summary below) when collapsed to
             icons on desktop. The mobile overlay always uses the full rail. --%>
        <div class={[if(@rail_collapsed, do: "lg:hidden", else: "")]}>
          {operator_controls(assigns)}
          <%!-- Inset divider between the operator block and the nav: a hairline
               cut short at both ends (mx-4) rather than edge-to-edge, so the
               separation reads cleaner than a full-width rule. The vertical
               margin gives the operator blocks and the nav clear breathing
               room from each other. --%>
          <div class="mx-4 my-2 border-t border-line"></div>
        </div>

        <%!-- Compact profile summary shown only in the collapsed desktop rail:
             level + karma values (no steppers). Clicking it expands the rail. --%>
        <button
          :if={@rail_collapsed}
          type="button"
          phx-click="toggle_rail"
          aria-label="Expand navigation"
          title="Operator - click to expand"
          class="hidden lg:flex flex-col items-center gap-0.5 w-full py-3 border-b border-line hover:bg-ink-800 transition-colors hud-focus"
        >
          {rank_emblem(%{
            level: @pmc_level,
            src: OperatorState.rank_image_path(@pmc_level),
            size: "w-9 h-9"
          })}
          <span class="t-label text-[7px] text-fog-500 mt-1">Level</span>
          <span class="t-num text-sm text-fog-100 leading-none">{@pmc_level}</span>
          <span class="t-label text-[7px] text-fog-500 mt-2">Karma</span>
          <span class={["t-num text-sm leading-none", karma_color(@scav_karma)]}>
            {@scav_karma}
          </span>
        </button>

        <nav class="pt-4 pb-3">
          <div class={["px-4 pb-2", if(@rail_collapsed, do: "lg:hidden", else: "")]}>
            <div class="t-label text-[9px] text-fog-500">Navigation</div>
          </div>
          <.nav_link
            :for={entry <- nav_entries()}
            entry={entry}
            active={@active}
            collapsed={@rail_collapsed}
          />
        </nav>
      </div>

      <%!-- Not a nav entry — there is no credits page to link to. Each source is
           credited in a line beside the content it applies to
           (`CoreComponents.source_credit/1`), and the Battlestate and
           non-commercial statements are in the footer.

           This is the standing acknowledgement of where the *data* comes from,
           which those per-page lines do not cover: tarkov.dev supplies the item,
           trader, task, ammo and hideout data, and no licence obliges us to say
           so — they publish none. It is here because it is right, and because
           the rail is on screen on every page.

           Uses the same inset rule as the operator/navigation divider above
           rather than a full-width container border, so the three rail sections
           are separated consistently. --%>
      <div :if={!@rail_collapsed} class="shrink-0">
        <div class="mx-4 my-2 border-t border-line"></div>
        <%!-- Centred and stacked: `whitespace-nowrap` on one line ran past the
             224px rail, and centring keeps the two short lines reading as one
             block rather than as a stray left-aligned fragment below the nav.

             Colour is declared once, on the wrapper. The links deliberately set
             no text colour of their own so they inherit it, which is what keeps
             the label, the "&" and both names identical — setting each
             separately is how they drifted apart in the first place.

             `fog-100` matches the inactive nav items above rather than the
             muted tone the rest of the app's small print uses: this is an
             acknowledgement we want read, not fine print to be skimmed past.
             The smaller type size and the underlines are what keep it from
             reading as another nav destination. --%>
        <div class="px-4 pb-3 space-y-0.5 text-center t-label text-[9px] text-fog-100">
          <p>Data from</p>
          <p class="leading-snug">
            <a
              href="https://tarkov.dev"
              target="_blank"
              rel="noopener noreferrer"
              class={rail_credit_link_class()}
            >
              tarkov.dev
            </a>
            &amp;
            <a
              href="https://escapefromtarkov.fandom.com/wiki/Escape_from_Tarkov_Wiki"
              target="_blank"
              rel="noopener noreferrer"
              class={rail_credit_link_class()}
            >
              EFT Wiki
            </a>
          </p>
        </div>
      </div>

      <%!-- Collapsed rail has no room for the sentence; the icon keeps the
           acknowledgement present rather than dropping it entirely. --%>
      <div :if={@rail_collapsed} class="hidden lg:block shrink-0">
        <div class="mx-4 my-2 border-t border-line"></div>
        <div
          title="Data from tarkov.dev & Escape from Tarkov Wiki"
          class="flex justify-center pb-3 text-fog-600"
        >
          <.icon name="hero-information-circle" class="w-4 h-4" />
        </div>
      </div>
    </aside>
    """
  end

  # ── Top bar (page title + global search + app-level actions) ───────

  defp top_bar(assigns) do
    ~H"""
    <header class={[
      "fixed top-0 right-0 left-0 z-40 h-14 bg-ink-900 border-b border-line",
      @bar_left
    ]}>
      <%!-- amber tracer line along the bottom edge --%>
      <div class="absolute bottom-0 inset-x-0 h-px hud-rule opacity-60"></div>

      <%!-- Equal 1fr side columns keep the search box viewport-centered
           regardless of how long the page title or action cluster is. --%>
      <div class="h-full px-3 sm:px-5 grid grid-cols-[auto_1fr_auto] lg:grid-cols-[1fr_minmax(0,26rem)_1fr] items-center gap-3">
        <%!-- left: rail toggle + page title --%>
        <div class="flex items-center gap-2 min-w-0">
          <%!-- desktop: collapse / expand the rail --%>
          <button
            type="button"
            phx-click="toggle_rail"
            aria-label="Toggle navigation"
            class="hidden lg:flex -ml-1 w-9 h-9 items-center justify-center text-fog-300 hover:text-amber transition-colors hud-focus"
          >
            <.icon name="hero-bars-3" class="w-6 h-6" />
          </button>
          <%!-- mobile: open the nav rail overlay --%>
          <button
            type="button"
            data-shell-rail-open
            aria-label="Open navigation"
            class="lg:hidden -ml-1 w-9 h-9 flex items-center justify-center text-fog-300 hover:text-amber transition-colors hud-focus"
          >
            <.icon name="hero-bars-3" class="w-6 h-6" />
          </button>
          <h1 :if={@page_title} class="t-head text-lg sm:text-xl text-fog-100 truncate">
            {@page_title}
          </h1>
        </div>

        <%!-- center: global search (only on pages that opt in via placeholder) --%>
        <div class="min-w-0 flex justify-center">
          <.search
            :if={@search_placeholder}
            id="global-search"
            value={@search_query || ""}
            placeholder={@search_placeholder}
            class="w-full max-w-md"
          />
        </div>

        <%!-- right: app-level actions --%>
        <div class="flex items-center justify-end gap-2">
          {backup_menu(assigns)}
          <.link
            navigate={~p"/report-bug"}
            class={[
              "inline-flex items-center gap-1.5 px-3 py-2 border t-label text-[11px] transition-colors hud-focus",
              if(@active == :report_bug,
                do: "text-amber border-amber bg-amber/5",
                else: "text-fog-400 border-line hover:text-amber hover:border-amber/60"
              )
            ]}
          >
            <.icon name="hero-bug-ant" class="w-4 h-4" />
            <span class="hidden sm:inline">Report</span>
          </.link>
        </div>
      </div>
    </header>
    """
  end

  # Progress backup menu (top-bar action). Export / import / reset of the
  # per-browser state (localStorage progress + prefs cookie). All three are
  # pure client operations handled by the `Backup` JS hook - no server events,
  # so the menu works even while the socket is reconnecting. Built as a native
  # <details> disclosure so open/close needs no JS and it's keyboard- and
  # screen-reader-friendly out of the box.
  defp backup_menu(assigns) do
    ~H"""
    <div id="progress-backup" phx-hook="Backup" class="relative">
      <details class="group" data-backup-root>
        <summary class={[
          "inline-flex items-center gap-1.5 px-3 py-2 border t-label text-[11px] transition-colors hud-focus",
          "cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden",
          "text-fog-400 border-line hover:text-amber hover:border-amber/60",
          "group-open:text-amber group-open:border-amber/60"
        ]}>
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
          <span class="hidden sm:inline">Backup</span>
          <.icon
            name="hero-chevron-down"
            class="w-3 h-3 transition-transform group-open:rotate-180"
          />
        </summary>

        <div class="absolute right-0 mt-1 w-56 bg-ink-900 border border-line shadow-xl z-50 py-1">
          <p class="px-3 py-1.5 t-label text-[9px] text-fog-600">Progress &amp; settings</p>
          <.backup_item action="export" icon="hero-arrow-down-tray" label="Export to file" />
          <.backup_item action="import" icon="hero-arrow-up-tray" label="Import from file" />
          <div class="my-1 border-t border-line"></div>
          <.backup_item action="reset" icon="hero-trash" label="Reset progress" danger />
        </div>
      </details>

      <%!-- Hidden picker for "Import from file"; opened by the Backup hook. --%>
      <input
        type="file"
        accept="application/json,.json"
        data-backup-file
        class="hidden"
        aria-hidden="true"
        tabindex="-1"
      />
    </div>
    """
  end

  attr :action, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :danger, :boolean, default: false

  defp backup_item(assigns) do
    ~H"""
    <button
      type="button"
      data-backup-action={@action}
      class={[
        "w-full flex items-center gap-2.5 px-3 py-2 text-left text-xs transition-colors hud-focus",
        if(@danger,
          do: "text-rust hover:bg-rust/10",
          else: "text-fog-300 hover:text-fog-100 hover:bg-ink-800"
        )
      ]}
    >
      <.icon name={@icon} class="w-4 h-4 shrink-0" />
      {@label}
    </button>
    """
  end

  attr :entry, :map, required: true
  attr :active, :atom, default: nil
  attr :collapsed, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@entry.href}
      aria-current={if @active == @entry.key, do: "page", else: "false"}
      title={@entry.label}
      class={[
        "group flex items-center gap-3 px-4 py-2.5 t-label text-xs border-l-2 transition-colors",
        if(@collapsed, do: "lg:justify-center lg:px-0", else: ""),
        if(@active == @entry.key,
          do: "text-amber bg-amber/12 border-amber",
          else: "text-fog-100 border-transparent hover:text-amber hover:bg-ink-800"
        )
      ]}
    >
      <.icon name={@entry.icon} class="w-5 h-5 shrink-0" />
      <span class={[if(@collapsed, do: "lg:hidden", else: "")]}>{@entry.label}</span>
    </.link>
    """
  end

  # Shared operator-controls body (the emulated in-game player state).
  defp operator_controls(assigns) do
    assigns =
      assigns
      |> assign_new(:rank_image, fn -> OperatorState.rank_image_path(assigns.pmc_level) end)
      |> assign_new(:panel_scope, fn -> "hud" end)

    ~H"""
    <div class="p-3 pt-4 space-y-6">
      <%!-- PMC level: emblem + big value + grouped stepper, all wrapped in one
           compact panel. The emblem still swaps by level via rank_image_path. --%>
      <div>
        <div class="t-label text-[9px] text-fog-500 mb-1.5">PMC Level</div>
        <div class="hud-panel flex items-center gap-2.5 px-2.5 py-2">
          {rank_emblem(%{level: @pmc_level, src: @rank_image, size: "w-11 h-11"})}
          <form
            phx-change="set_pmc_level"
            phx-submit="set_pmc_level"
            class="flex-1 min-w-0"
          >
            <input
              type="number"
              id={"pmc-level-#{@panel_scope}"}
              name="pmc_level"
              value={@pmc_level}
              min={OperatorState.min_level()}
              max={OperatorState.max_level()}
              inputmode="numeric"
              phx-hook="LevelInput"
              phx-debounce="300"
              aria-label="PMC level"
              class="no-spin w-full bg-transparent border-0 t-num text-2xl text-fog-100 leading-none text-center hud-focus"
            />
          </form>
          <.stepper
            inc_event="pmc_level_inc"
            dec_event="pmc_level_dec"
            inc_label="Increase PMC level"
            dec_label="Decrease PMC level"
            inc_disabled={@pmc_level >= OperatorState.max_level()}
            dec_disabled={@pmc_level <= OperatorState.min_level()}
          />
        </div>
      </div>

      <%!-- Scav karma (Fence reputation): -6.00 .. +6.00. A horizontal slider,
           but it drives the SAME `set_scav_karma` event the old numeric field
           did - the server stays the source of truth, re-clamps, and the Tasks
           page keeps gating on the resulting :scav_karma assign. `phx-debounce`
           (not throttle) commits the released value reliably, so karma-gated
           quests update exactly as before. The `KarmaSlider` hook only paints
           the fill + readout for live feedback while dragging; those two nodes
           are `phx-update="ignore"` so a navigation patch never wipes the
           painted state (the hook re-syncs them from the input on update). --%>
      <div id={"scav-karma-#{@panel_scope}"} phx-hook="KarmaSlider" data-karma>
        <div class="t-label text-[9px] text-fog-500 mb-1.5">Scav Karma</div>
        <form phx-change="set_scav_karma" phx-submit="set_scav_karma" class="karma-slider">
          <span class="karma-slider__rail" aria-hidden="true">
            <span
              id={"scav-karma-fill-#{@panel_scope}"}
              class="karma-slider__fill"
              data-karma-fill
              phx-update="ignore"
              style={karma_fill_style(@scav_karma)}
            >
            </span>
            <span class="karma-slider__zero"></span>
          </span>
          <input
            type="range"
            name="scav_karma"
            value={@scav_karma}
            min={OperatorState.min_karma()}
            max={OperatorState.max_karma()}
            step="0.01"
            data-karma-input
            phx-debounce="120"
            aria-label="Scav karma"
            class="karma-slider__input hud-focus"
          />
        </form>
        <div class="flex justify-between t-num text-[9px] text-fog-600 mt-1 px-0.5">
          <span>-6</span>
          <span>0</span>
          <span>+6</span>
        </div>
        <%!-- Manual value entry (mirrors the PMC level field): the same
             `set_scav_karma` event, clamped by NumberCap. The slider and this
             field are kept in sync client-side by the KarmaSlider hook. --%>
        <form
          phx-change="set_scav_karma"
          phx-submit="set_scav_karma"
          class="mt-1 flex justify-center"
        >
          <input
            type="number"
            id={"scav-karma-input-#{@panel_scope}"}
            name="scav_karma"
            value={@scav_karma}
            min={OperatorState.min_karma()}
            max={OperatorState.max_karma()}
            step="0.01"
            inputmode="decimal"
            data-karma-number
            phx-hook="NumberCap"
            phx-debounce="400"
            aria-label="Scav karma"
            class={[
              "no-spin w-20 bg-transparent border-0 t-num text-lg leading-none text-center hud-focus",
              karma_color(@scav_karma)
            ]}
          />
        </form>
      </div>

      <%!-- Game settings: mode (PVP/PVE) + faction (USEC/BEAR), grouped under a
           single label to match the PMC Level / Scav Karma blocks above. The
           USEC/BEAR emblems are darkened from their bright silver finish to a
           muted grey so they sit in the theme. --%>
      <div>
        <div class="t-label text-[9px] text-fog-500 mb-1.5">Game Settings</div>
        <div class="space-y-1.5">
          <div class="grid grid-cols-2 gap-1.5">
            <.toggle_btn
              event="set_mode"
              param="mode"
              value="pvp"
              label="PVP"
              icon="/images/icons/pvp.webp"
              active={@mode == :pvp}
              accent="amber"
            />
            <.toggle_btn
              event="set_mode"
              param="mode"
              value="pve"
              label="PVE"
              icon="/images/icons/pve.webp"
              active={@mode == :pve}
              accent="signal"
            />
          </div>
          <div class="grid grid-cols-2 gap-1.5">
            <.toggle_btn
              event="set_faction"
              param="faction"
              value="usec"
              label="USEC"
              icon="/images/icons/usec.webp"
              img_class="icon-white"
              active={@faction == :usec}
              accent="neutral"
            />
            <.toggle_btn
              event="set_faction"
              param="faction"
              value="bear"
              label="BEAR"
              icon="/images/icons/bear.webp"
              img_class="icon-white"
              active={@faction == :bear}
              accent="neutral"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :inc_event, :string, required: true
  attr :dec_event, :string, required: true
  attr :inc_label, :string, required: true
  attr :dec_label, :string, required: true
  attr :inc_disabled, :boolean, default: false
  attr :dec_disabled, :boolean, default: false

  # Grouped vertical +/- stepper (increment on top), styled after the
  # TarkovTracker level control: one bordered box with a hairline divider.
  defp stepper(assigns) do
    ~H"""
    <div class="flex flex-col shrink-0 border border-line divide-y divide-line">
      <.stepper_btn event={@inc_event} icon="hero-plus" label={@inc_label} disabled={@inc_disabled} />
      <.stepper_btn event={@dec_event} icon="hero-minus" label={@dec_label} disabled={@dec_disabled} />
    </div>
    """
  end

  attr :event, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  defp stepper_btn(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      aria-label={@label}
      disabled={@disabled}
      class="w-8 h-6 flex items-center justify-center text-fog-200 hover:text-amber hover:bg-ink-800 transition-colors disabled:opacity-30 disabled:hover:text-fog-200 disabled:hover:bg-transparent hud-focus"
    >
      <.icon name={@icon} class="w-4 h-4" />
    </button>
    """
  end

  attr :event, :string, required: true
  attr :param, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :accent, :string, default: "amber"
  attr :img_class, :string, default: ""

  defp toggle_btn(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      {%{"phx-value-#{@param}" => @value}}
      aria-pressed={@active}
      class={[
        "t-label text-xs py-1.5 border flex items-center justify-center gap-1.5 transition-colors hud-focus",
        toggle_btn_class(@accent, @active)
      ]}
    >
      <img
        src={@icon}
        alt=""
        aria-hidden="true"
        class={["h-4 w-auto object-contain shrink-0", @img_class]}
      />
      {@label}
    </button>
    """
  end

  # PVP (amber/gold) and PVE (signal/blue): unselected they share the same
  # black background + neutral outline as the USEC/BEAR faction buttons;
  # when selected they take on their identity colour as the background +
  # outline (gold for PVP, blue for PVE) so the active mode is unmistakable.
  defp toggle_btn_class("amber", true), do: "bg-amber/20 text-amber border-amber"

  defp toggle_btn_class("amber", false),
    do: "bg-ink-950 text-amber border-line hover:border-line-strong"

  defp toggle_btn_class("signal", true), do: "bg-signal/20 text-signal border-signal"

  defp toggle_btn_class("signal", false),
    do: "bg-ink-950 text-signal border-line hover:border-line-strong"

  defp toggle_btn_class("neutral", true), do: "bg-fog-300/10 text-fog-100 border-fog-400"

  # USEC/BEAR faction buttons: keep the label text white (text-fog-100 - the
  # same white the highlighted/active state uses) even when the button is
  # inactive, instead of the muted fog-500 the generic toggle uses. Only the
  # text colour changes; the background + outline stay the resting style.
  defp toggle_btn_class("neutral", false),
    do: "bg-ink-950 text-fog-100 border-line hover:border-line-strong"

  defp toggle_btn_class(_, _),
    do: "bg-ink-950 text-fog-500 border-line hover:text-fog-100 hover:border-line-strong"

  # ── Footer ─────────────────────────────────────────────────────────

  defp footer(assigns) do
    ~H"""
    <footer class="border-t border-line bg-ink-950">
      <div class="max-w-[1800px] mx-auto px-4 sm:px-6 py-5 space-y-1.5 text-center">
        <%!-- Contact row. This is the takedown route: if a rights holder, a wiki
             contributor or an asset author wants something corrected or removed,
             this is how they reach us. It has to be on every page, because the
             thing they object to could be on any of them.

             The address itself is not printed — it sits behind the word, which
             keeps the line short and keeps a plain-text address off every page
             for scrapers to harvest. `t-label` upper-cases it, so this renders
             as "EMAIL" in the same stencil style as the label beside it. --%>
        <p class="t-label text-[9px] text-fog-600">
          Corrections &amp; takedowns ·
          <a href={"mailto:" <> contact_email()} class={footer_link_class()}>Email</a>
          <%!-- `href`, not `navigate`: /privacy is a plain controller route, so it
               is outside `live_session :operator` and a live navigation cannot
               reach it. --%>
          · <.link href={~p"/privacy"} class={footer_link_class()}>Privacy</.link>
        </p>

        <p class="t-label text-[10px] text-fog-600">
          EFT Buddy © 2026 · v{app_version()}
        </p>

        <%!-- Battlestate's marks appear on any page that renders an item icon or
             a screenshot, so this stays site-wide. "Non-commercial" is not only
             a product promise: the wiki prose and the vendored map artwork are
             both licensed for non-commercial use only, so it is a condition we
             are held to. Upstream content licences are named in the credit line
             beside the content itself. --%>
        <p class="text-xs text-fog-600 leading-snug max-w-3xl mx-auto">
          Escape from Tarkov and related content are trademarks and copyrighted works of Battlestate
          Games Limited and its licensors. All rights reserved. EFT Buddy is an unofficial,
          non-commercial fan project and is not affiliated with or endorsed by Battlestate Games.
        </p>
      </div>
    </footer>
    """
  end

  # No text colour: these inherit it from the block so the whole acknowledgement
  # is one tone. Only the underline marks them as links at rest, with amber on
  # hover as everywhere else in the app.
  defp rail_credit_link_class do
    "hover:text-amber underline decoration-line " <>
      "hover:decoration-amber/60 underline-offset-2 transition-colors"
  end

  @doc """
  The project's contact address, used for corrections, takedowns and privacy
  questions.

  Public so `/privacy` renders the same address as the footer instead of
  repeating the literal — two copies of a contact address is one copy that
  eventually goes stale.
  """
  def contact_email, do: "eftbuddy.splotchy319@passmail.net"

  # Inherits the surrounding label's size and family so the address reads as
  # part of the same line, not as a separate control. Amber on hover is the
  # app's link idiom; the earlier blue made it the loudest thing in the footer.
  defp footer_link_class do
    "text-fog-500 hover:text-amber underline decoration-line " <>
      "hover:decoration-amber/60 underline-offset-2 transition-colors"
  end

  # Read from the built application rather than hardcoded, so a release bump
  # cannot leave a stale build number sitting in the footer of every page.
  defp app_version do
    case Application.spec(:eft_buddy, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  # ── Shared marks / emblems ─────────────────────────────────────────

  attr :level, :integer, required: true
  attr :src, :string, required: true
  attr :size, :string, default: "w-16 h-16"

  defp rank_emblem(assigns) do
    ~H"""
    <div class={["relative shrink-0", @size]}>
      <img
        src={@src}
        alt={"Rank emblem for level #{@level}"}
        class={["object-contain img-fallback", @size]}
      />
      <div style="display:none;" class="absolute inset-0">
        <svg viewBox="0 0 60 60" class="w-full h-full">
          <polygon
            points="30,3 54,16 54,44 30,57 6,44 6,16"
            fill="#181818"
            stroke="#9a8866"
            stroke-width="2"
          />
        </svg>
        <span class="absolute inset-0 flex items-center justify-center t-num text-sm text-fog-100">
          {@level}
        </span>
      </div>
    </div>
    """
  end

  # ── Nav entries ────────────────────────────────────────────────────

  defp nav_entries do
    [
      %{key: :events, href: "/events", icon: "hero-calendar-days", label: "Events"},
      %{key: :storyline, href: "/storyline", icon: "hero-book-open", label: "Storyline"},
      %{key: :tasks, href: "/tasks", icon: "hero-clipboard-document-check", label: "Tasks"},
      %{key: :maps, href: "/maps", icon: "hero-map", label: "Maps"},
      %{key: :items, href: "/items", icon: "hero-cube", label: "Items"},
      %{
        key: :flea_market,
        href: "/flea-market",
        icon: "hero-arrow-trending-up",
        label: "Flea Market"
      },
      %{key: :hideout, href: "/hideout", icon: "hero-home", label: "Hideout"},
      %{key: :ammo, href: "/ammo", icon: "hero-fire", label: "Ballistics"}
    ]
  end

  # Karma readout colour: green when positive, rust when negative, neutral at
  # zero (matches the in-game Fence-rep sentiment).
  defp karma_color(value) when is_number(value) and value > 0, do: "text-go"
  defp karma_color(value) when is_number(value) and value < 0, do: "text-rust"
  defp karma_color(_), do: "text-fog-100"

  # Inline style for the karma slider's fill bar: it grows from the centre (0)
  # out towards the thumb - green to the right for positive karma, rust to the
  # left for negative, nothing at zero. Rendered server-side so the fill is
  # already correct on first paint (before the hook runs) and never flashes.
  defp karma_fill_style(value) when is_number(value) and value > 0 do
    "left:50%;right:#{Float.round(100.0 - karma_pct(value), 2)}%;background:var(--color-go)"
  end

  defp karma_fill_style(value) when is_number(value) and value < 0 do
    "left:#{Float.round(karma_pct(value), 2)}%;right:50%;background:var(--color-rust)"
  end

  defp karma_fill_style(_), do: "left:50%;right:50%"

  # Position of a karma value along the -6..+6 track, as a 0..100 percentage.
  defp karma_pct(value) do
    min = OperatorState.min_karma()
    max = OperatorState.max_karma()
    (value - min) / (max - min) * 100.0
  end

  # ── Flash group ────────────────────────────────────────────────────

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
