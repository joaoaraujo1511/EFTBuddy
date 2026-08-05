defmodule EftBuddyWeb.HideoutLive.Index do
  use EftBuddyWeb, :live_view

  alias EftBuddy.Hideout
  alias EftBuddy.Progress
  alias EftBuddyWeb.ClientBridge

  # Keys (inside the ACTIVE GAME MODE's slice of the progress blob) the hideout
  # board is stored under: a `%{slug => level}` map of built stations, and the
  # flat list of manually-ticked "{slug}:{level}:{req_id}" requirement keys.
  # PVE has its own hideout in-game, so both are per mode - see
  # `EftBuddy.Progress`.
  @levels_key "hideout"
  @checks_key "hideout_checks"

  @impl true
  def mount(_params, _session, socket) do
    # Build the module list (with per-level requirement queries) only on
    # the connected mount so the work isn't done twice; the disconnected
    # static render shows an empty grid for a blink.
    modules = if connected?(socket), do: build_initial_modules(), else: []

    socket =
      socket
      |> assign(:page_title, "Hideout")
      |> assign(
        :page_description,
        "Plan every Escape from Tarkov hideout station: item, skill and trader requirements with cumulative build costs per module."
      )
      |> assign(:active, :hideout)
      # Sections start closed by default. Users bounce between modules
      # constantly and showing every section open made the page noisy;
      # they can expand the bits they care about per visit.
      |> assign(:expanded, MapSet.new())
      # Manually-ticked requirements, as a set of "{slug}:{level}:{req_id}"
      # keys. Each module's status (locked / missing items / ready) is
      # derived purely from these ticks - fully manual tracking, mirroring
      # the Tasks page. Hydrated from `@client_state` (the server-authoritative
      # progress blob) below, so ticks and station levels are already correct in
      # the first render on every navigation.
      |> then(&assign(&1, :checked, read_checks(&1)))
      |> assign(:modules, modules)
      # Active filter from the top options bar. One of:
      #   :all (default), :available, :locked, :maxed
      # Actually set by handle_params/3 below; we initialise to :all
      # so the first render before patching has a sensible default.
      |> assign(:filter, :all)
      # Free-text search box above the grid. Trimmed + lowercased
      # before being matched against module names so trailing spaces
      # and casing don't trip the user up.
      |> assign(:query, "")

    # Snap the freshly-built modules to their persisted levels. Safe to run on
    # the disconnected render too: `modules` is empty there, so it's a no-op.
    {:ok, apply_hideout_levels(socket, read_levels(socket))}
  end

  @impl true
  # Read the `?view=` query param into `:filter`, plus the `?q=`
  # search query into `:query`. Driven by the top options-bar tabs
  # and the search box, both of which navigate via `<.link patch>`
  # / `push_patch` so the URL stays shareable / bookmarkable / back-
  # button friendly. Industry-standard practice for any page where
  # the user can narrow the view - refreshing the page or sharing a
  # link reproduces exactly the same state.
  def handle_params(params, _uri, socket) do
    query =
      params
      |> Map.get("q", "")
      |> to_string()
      |> String.slice(0, 200)

    {:noreply,
     socket
     |> assign(:filter, parse_filter(params["view"]))
     |> assign(:query, query)}
  end

  defp parse_filter("all"), do: :all
  defp parse_filter("available"), do: :available
  defp parse_filter("locked"), do: :locked
  defp parse_filter("maxed"), do: :maxed
  defp parse_filter(_), do: :all

  @impl true
  # Toggles a per-module section open/closed. The `expanded` MapSet stores
  # "{slug}:{section}" strings; section is "prerequisites", "needed" or
  # "items_used".
  #
  # We re-run the position lock here so that *collapsing* a module (the
  # user "leaving" it) applies any sort that was deferred while they were
  # working on it - a card that became READY while expanded now drops into
  # its bucket. Opening a section just pins the card, which leaves the
  # order unchanged.
  def handle_event("toggle_section", %{"slug" => slug, "section" => section}, socket) do
    key = "#{slug}:#{section}"
    expanded = socket.assigns.expanded

    new_expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    modules = reorder_locking_expanded(socket.assigns.modules, new_expanded)

    {:noreply,
     socket
     |> assign(:expanded, new_expanded)
     |> assign(:modules, modules)}
  end

  # Free-text search. The Flea Market and Items pages use the same
  # `phx-change="search"` shape with a debounced input, so this
  # mirrors them. We patch the URL so the active query lives in
  # `?q=...` and `handle_params/3` picks it up - that keeps the
  # search shareable / refresh-safe alongside the options-bar
  # filter. `replace: true` keeps the browser history clean.
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket,
       to: hideout_path(query, socket.assigns.filter),
       replace: true
     )}
  end

  # X button on the search box clears the input by patching to a
  # URL without the `?q=` param. Goes through `handle_params/3` so
  # the search query and any other state are reset together.
  def handle_event("clear_search", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: hideout_path("", socket.assigns.filter),
       replace: true
     )}
  end

  # Toggle a single needed item done/undone for the level a module would
  # build next. The tick set is keyed by "{slug}:{level}:{req_id}" so each
  # level tracks its own requirements; bumping the level naturally reveals
  # a fresh, un-ticked set. A module's status is recomputed from the ticks,
  # so this can flip a card between missing items / ready. Persisted to
  # localStorage. Prerequisites are never toggled here - they're read-only
  # and gated on real module levels.
  #
  # The card is always expanded while the user ticks items (they had to
  # open "Needed Items" to see them), so `reorder_locking_expanded/2`
  # holds its position steady even when the last tick flips it to READY -
  # it only re-sorts once the user collapses the section.
  # Every part of the key is resolved against this socket's own catalogue before it
  # is used. `phx-value-*` arrives as whatever the client sends, and this key is
  # built by interpolation and then ACCUMULATED into the operator's progress blob -
  # so without the check the tick set was an unbounded, attacker-chosen string set
  # that `EftBuddy.Progress` then had to hold for four hours. Validating against
  # `modules` makes its cardinality intrinsically bounded by the real station list,
  # which is a stronger bound than any byte ceiling.
  #
  # The `is_binary` guards matter separately: a map or list in `level` would raise
  # `Protocol.UndefinedError` inside the interpolation and take the LiveView down.
  def handle_event(
        "toggle_requirement",
        %{"slug" => slug, "level" => level, "req" => req},
        socket
      )
      when is_binary(slug) and is_binary(level) and is_binary(req) do
    with %{} = mod <- Enum.find(socket.assigns.modules, &(&1.slug == slug)),
         # Ticks are keyed per level and only the module's NEXT level is rendered,
         # so anything else is either stale markup or forged.
         true <- level == to_string(target_level(mod)),
         true <- Enum.any?(mod.needed, &(to_string(&1.id) == req)) do
      key = req_key(slug, level, req)
      checked = socket.assigns.checked

      checked =
        if MapSet.member?(checked, key),
          do: MapSet.delete(checked, key),
          else: MapSet.put(checked, key)

      modules =
        socket.assigns.modules
        |> recompute_statuses(checked)
        |> reorder_locking_expanded(socket.assigns.expanded)

      {:noreply,
       socket
       |> assign(:checked, checked)
       |> assign(:modules, modules)
       |> ClientBridge.put_progress(%{@checks_key => MapSet.to_list(checked)})}
    else
      _ -> {:noreply, socket}
    end
  end

  # An unknown station, a stale level, or a non-string payload: ignore it. A
  # LiveView with no matching clause crashes, and a crash here reconnects into the
  # same forged push.
  def handle_event("toggle_requirement", _params, socket), do: {:noreply, socket}

  # Increment a module's current level by 1 (capped at its max). Only
  # allowed once every prerequisite and needed item for the next level
  # has been ticked (status `:ready`); the button is disabled otherwise,
  # and this guard is the server-side backstop. Downgrade is only
  # available once the module is past its min level.
  def handle_event("upgrade", %{"slug" => slug}, socket) do
    case Enum.find(socket.assigns.modules, &(&1.slug == slug)) do
      %{status: :ready} -> {:noreply, update_module_level(socket, slug, +1)}
      _ -> {:noreply, socket}
    end
  end

  # Decrement a module's current level by 1 (floored at 0). The
  # downgrade button is only rendered when current > 1, so in practice
  # this lands a module back at lvl 1 at the lowest from a UI click.
  def handle_event("downgrade", %{"slug" => slug}, socket) do
    {:noreply, update_module_level(socket, slug, -1)}
  end

  # The progress blob changed: either a cold connect handing up localStorage for
  # the first time, or another of the operator's tabs editing it. On a live
  # navigation the blob is already present in `mount/3`, so this no longer fires
  # there. We restore both the per-station levels and the ticked requirements we
  # own, then recompute every module's status against them.
  @impl true
  def handle_info({:client_state_restored, state}, socket) when is_map(state) do
    socket =
      socket |> assign(:client_state, state) |> then(&assign(&1, :checked, read_checks(&1)))

    {:noreply, apply_hideout_levels(socket, read_levels(socket))}
  end

  # PVE has its own hideout in-game, so the station levels and the ticked
  # requirements are stored per game mode: a PVP/PVE flip has to reload the whole
  # board from the other mode's slice.
  def handle_info({:sidebar_state_changed, :mode, _value}, socket) do
    socket = then(socket, &assign(&1, :checked, read_checks(&1)))

    {:noreply, apply_hideout_levels(socket, read_levels(socket))}
  end

  # `EftBuddyWeb.OperatorState` pings every LiveView with
  # `{:sidebar_state_changed, ...}` after a HUD change. The hideout
  # page derives nothing from the rest of them, but once a LiveView defines
  # `handle_info/2` it must handle every message it can receive - so we
  # add a permissive fall-through to ignore them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc """
  Build a `/hideout` path with the given filter pair preserved as
  query params. Used by the search box's clear-X link and by the
  search event handler so toggling one filter never silently drops
  the other. The default values (`""` query, `:all` filter) are
  omitted so the bare `/hideout` URL stays clean.
  """
  def hideout_path(query, filter) do
    params =
      []
      |> maybe_put(:view, view_param(filter))
      |> maybe_put(:q, query_param(query))

    case params do
      [] -> "/hideout"
      _ -> "/hideout?" <> URI.encode_query(params)
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, value}]

  defp view_param(:all), do: nil
  defp view_param(filter) when is_atom(filter), do: Atom.to_string(filter)
  defp view_param(_), do: nil

  defp query_param(""), do: nil
  defp query_param(nil), do: nil
  defp query_param(q) when is_binary(q), do: q

  # Adjust the `:current` level of the module identified by `slug` by
  # `delta`, clamped to [0, max], and refresh its `:prerequisites` /
  # `:needed` lists with the requirements for the *next* level the
  # player would build (current + 1). The new level's requirements are
  # un-ticked (ticks are keyed per level), so we recompute this module's
  # status and re-sort afterwards.
  defp update_module_level(socket, slug, delta) do
    modules =
      socket.assigns.modules
      |> Enum.map(fn
        %{slug: ^slug, current: current, max: max, min_level: min_level} = mod ->
          Map.put(mod, :current, clamp(current + delta, min_level, max))

        mod ->
          mod
      end)
      |> populate_all([slug])
      |> recompute_statuses(socket.assigns.checked)
      |> reorder_locking_expanded(socket.assigns.expanded)

    socket
    |> assign(:modules, modules)
    |> ClientBridge.put_progress(%{@levels_key => current_levels(modules)})
  end

  # Restore persisted station levels from the client localStorage blob.
  # `levels` is a `%{slug => current_level}` map (string keys, integer
  # values) taken from the operator's progress blob. We snap each known
  # module to its persisted level
  # (clamped to that module's valid range), refresh its requirement
  # lists for the next buildable level, then recompute cross-module
  # prereqs and re-sort. Unknown slugs in the blob (e.g. a station that
  # was renamed/removed) are simply ignored.
  defp apply_hideout_levels(socket, levels) when is_map(levels) do
    modules =
      socket.assigns.modules
      |> Enum.map(fn %{slug: slug, max: max, min_level: min_level} = mod ->
        case Map.get(levels, slug) do
          level when is_integer(level) -> Map.put(mod, :current, clamp(level, min_level, max))
          _ -> mod
        end
      end)
      |> populate_all()
      |> recompute_statuses(socket.assigns.checked)
      |> sort_by_status()

    assign(socket, :modules, modules)
  end

  # No persisted levels (a fresh visitor, or a reset that emptied the blob), so
  # every module returns to its base level. On a normal mount the modules are
  # already there and this is a no-op; after a cross-tab reset it's what stops
  # the page keeping built stations while their ticks disappear.
  #
  # This clause is the one the reported slowness came from. `read_levels/1`
  # returns nil for a fresh visitor AND for every cold connect before the
  # browser hands up `localStorage`, so it runs on essentially every first
  # mount — and it used to call the single-station fetch once per station.
  defp apply_hideout_levels(socket, _levels) do
    modules =
      socket.assigns.modules
      |> Enum.map(fn %{min_level: min_level} = mod -> Map.put(mod, :current, min_level) end)
      |> populate_all()
      |> recompute_statuses(socket.assigns.checked)
      |> reorder_locking_expanded(socket.assigns.expanded)

    assign(socket, :modules, modules)
  end

  # Pull the active game mode's ticked-requirement set out of the progress blob,
  # defensively: a missing / malformed entry yields an empty set. Stored as a
  # flat list of "{slug}:{level}:{req_id}" keys.
  defp read_checks(%{assigns: %{client_state: state, mode: mode}}) do
    case Progress.get(state, mode, @checks_key) do
      list when is_list(list) -> list |> Enum.filter(&is_binary/1) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  # The active game mode's persisted `%{slug => level}` map.
  defp read_levels(%{assigns: %{client_state: state, mode: mode}}) do
    Progress.get(state, mode, @levels_key)
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  @doc "Returns true if a given section of a given module is expanded."
  def expanded?(expanded, slug, section),
    do: MapSet.member?(expanded, "#{slug}:#{section}")

  @doc """
  Filter the module list down to only the cards that match the active
  top-bar tab. `:locked` matches modules whose prereqs are unmet
  (regardless of whether they're at level 0 or not - though in
  practice levelled modules have prereqs met by definition).
  `:available` matches anything the player can act on right now:
  ready-to-build *and* still-missing-items cards both qualify, since
  the user just needs the items to finish.
  """
  def filter_modules(modules, :all), do: modules

  def filter_modules(modules, :maxed) do
    Enum.filter(modules, &(module_status(&1) == :max_level))
  end

  def filter_modules(modules, :locked) do
    Enum.filter(modules, &(module_status(&1) == :missing_prereqs))
  end

  def filter_modules(modules, :available) do
    Enum.filter(modules, fn mod ->
      module_status(mod) in [:ready, :missing_items]
    end)
  end

  @doc """
  Narrow the module list to those whose name matches the user's
  search query. Match is case-insensitive substring on the trimmed
  query - same shape the Flea Market and Items pages use. An empty
  query is a no-op.
  """
  def search_modules(modules, query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        modules

      trimmed ->
        needle = String.downcase(trimmed)

        Enum.filter(modules, fn mod ->
          String.contains?(String.downcase(mod.name), needle)
        end)
    end
  end

  def search_modules(modules, _), do: modules

  @doc """
  Label for the green Upgrade/Build button. "Build" only when the
  module is at level 0; otherwise we tell the player which level
  they're moving to so they don't have to do the math. Stash never
  shows "Build" because its `:min_level` is 1 - there's no lvl 0
  state for it.
  """
  def upgrade_label(%{current: 0}), do: "Build"
  def upgrade_label(%{current: current}), do: "Upgrade to Lvl #{current + 1}"

  @doc """
  Label for the red Downgrade/Dismantle button. The lvl 1 → 0
  step is a full teardown so it reads "Dismantle"; every other
  step backwards reads as a plain "Downgrade" - we deliberately
  don't include the target level here, because the player is
  already looking at the current level on the card and the extra
  "to Lvl N" was visual noise. The button is hidden by the
  template at `:min_level` so we never need to handle the case
  where there's nowhere to go.
  """
  def downgrade_label(%{current: 1, min_level: 0}), do: "Dismantle"
  def downgrade_label(_module), do: "Downgrade"

  @doc """
  Whether the red Downgrade/Dismantle button should render. Hidden
  at `:min_level` (lvl 0 for most modules, lvl 1 for Stash since
  Stash has no "no stash" state in the game).
  """
  def downgrade_available?(%{current: current, min_level: min_level}),
    do: current > min_level

  @doc """
  Derive a module's UI status from its data. Four states drive both the
  status badge and the icon-chip color:

    * `:max_level` - gold; module is at max level. The Prerequisites
      and Needed Items sections are hidden in this case.
    * `:ready` - green; prereqs met and no items are needed (or any
      needed items are already on hand).
    * `:missing_items` - red; prereqs met but the player still needs
      items in their inventory before this can be built/upgraded.
    * `:missing_prereqs` - grey; another module or character level is
      blocking this one. The earliest state most modules sit in.
  """
  @spec module_status(map()) :: :max_level | :ready | :missing_items | :missing_prereqs
  def module_status(%{status: status}), do: status

  # Recompute every module's `:status`. Called after any level change or
  # requirement toggle, and on restore.
  #
  # Station prerequisites are auto-derived from the *actual* current
  # level of every module (built once here as `levels_by_slug`), so
  # upgrading one module can unlock everything that depends on it on the
  # next pass. Item requirements are still manual ticks.
  defp recompute_statuses(modules, checked) do
    levels_by_slug = Map.new(modules, &{&1.slug, &1.current})

    Enum.map(modules, fn mod ->
      Map.put(mod, :status, compute_status(mod, checked, levels_by_slug))
    end)
  end

  # Derive a module's status for the level it would build next. Missing
  # prerequisites take priority over missing items, so a still-locked
  # module never reads as merely "missing items". Prereqs are gated on
  # real module levels (station prereqs only); items on manual ticks.
  defp compute_status(%{current: current, max: max}, _checked, _levels) when current >= max,
    do: :max_level

  defp compute_status(mod, checked, levels_by_slug) do
    target = target_level(mod)
    prereqs_met? = station_prereqs_met?(mod, levels_by_slug)
    items_met? = all_checked?(checked, mod.slug, target, mod.needed)

    cond do
      not prereqs_met? -> :missing_prereqs
      not items_met? -> :missing_items
      true -> :ready
    end
  end

  # A module's station prerequisites are met when every referenced module
  # is at least at the required level. Skill/trader prereqs are ignored
  # here - they're untrackable and so never block a build. A module with
  # no station prereqs is trivially met.
  defp station_prereqs_met?(mod, levels_by_slug) do
    mod.prerequisites
    |> Enum.filter(&(&1.kind == :station))
    |> Enum.all?(fn req -> Map.get(levels_by_slug, req.slug, 0) >= req.required_level end)
  end

  defp all_checked?(checked, slug, level, reqs) do
    Enum.all?(reqs, &requirement_checked?(checked, slug, level, &1.id))
  end

  @doc "The level a module would build next - what its requirements are for."
  def target_level(%{current: current}), do: current + 1

  @doc "Storage/lookup key for a single requirement tick."
  def req_key(slug, level, req_id), do: "#{slug}:#{level}:#{req_id}"

  @doc "Whether a given requirement has been ticked for a module's next level."
  def requirement_checked?(checked, slug, level, req_id),
    do: MapSet.member?(checked, req_key(slug, level, req_id))

  @doc "How many of `reqs` are ticked for a module's next level (progress badge)."
  def checked_count(checked, slug, level, reqs),
    do: Enum.count(reqs, &requirement_checked?(checked, slug, level, &1.id))

  @doc "Human-readable label for the status badge."
  def status_label(:max_level), do: "MAXED"
  def status_label(:ready), do: "READY TO BUILD"
  def status_label(:missing_items), do: "MISSING ITEMS"
  def status_label(:missing_prereqs), do: "LOCKED"

  @doc "Tailwind classes for the right-side status badge."
  def status_classes(:max_level), do: "bg-amber/10 text-amber border-amber/40"
  def status_classes(:ready), do: "bg-go/10 text-go border-go/40"
  def status_classes(:missing_items), do: "bg-rust/10 text-rust border-rust/40"
  def status_classes(:missing_prereqs), do: "bg-ink-900 text-fog-300 border-line-strong"

  @doc """
  Tailwind classes for the icon "chip" on each module card. Mirrors the
  status colors.
  """
  def icon_chip_classes(:max_level), do: "bg-amber/15 border border-amber/40"
  def icon_chip_classes(:ready), do: "bg-go/15 border border-go/40"
  def icon_chip_classes(:missing_items), do: "bg-rust/15 border border-rust/40"
  def icon_chip_classes(:missing_prereqs), do: "bg-ink-950 border border-line-strong"

  @doc false
  def progress_percent(%{current: _, max: 0}), do: 0

  def progress_percent(%{current: current, max: max}) when max > 0,
    do: round(current / max * 100)

  @doc """
  Returns the asset path for a hideout module's icon.

  Files are vendored under `priv/static/images/hideout/{slug}.webp`.
  If a file is missing, the CSP-safe `js-img-fallback` listener in
  app.js reveals an inline SVG placeholder so the UI stays usable while
  the rest of the icons are vendored in.
  """
  def icon_path(%{slug: slug}), do: "/images/hideout/#{slug}.webp"

  @doc """
  Collapsible section inside a module card (e.g. Prerequisites / Needed
  Items). Sized for repeated use: noticeably bigger than a sidebar
  eyebrow, with chevron indicator that flips when the section is open.
  Color treatment matches the sidebar nav links - muted text by default,
  gold on hover - so the two collapsibles feel like part of the same
  navigation language.
  """
  attr :item, :map, required: true
  attr :checkable, :boolean, default: false
  attr :checked, :boolean, default: false
  attr :slug, :string, default: nil
  attr :level, :integer, default: nil

  def hideout_item_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.check_toggle
        :if={@checkable}
        checked={@checked}
        phx-click="toggle_requirement"
        phx-value-slug={@slug}
        phx-value-level={@level}
        phx-value-req={@item.id}
        label={"Mark #{@item.name} collected"}
      />
      <.link
        navigate={"/items?q=" <> URI.encode_www_form(@item.name)}
        class="flex items-center justify-between text-xs px-2 py-1 flex-1 min-w-0 hover:bg-ink-900 transition-colors group/item"
      >
        <span class="flex items-center gap-2 min-w-0 flex-1">
          <img
            :if={@item.icon}
            src={@item.icon}
            alt=""
            class="w-8 h-8 object-contain shrink-0 border border-line"
            loading="lazy"
          />
          <span class="text-fog-200 group-hover/item:text-amber truncate transition-colors">
            {@item.name}
          </span>
        </span>
        <span class="t-num text-amber shrink-0 ml-2">×{@item.qty}</span>
      </.link>
    </div>
    """
  end

  @doc """
  A single prerequisite row (station / skill / trader) with its icon.
  Traders use their tarkov.dev portrait, stations reuse the vendored
  module icon, and skills (which have no artwork) fall back to a
  heroicon glyph. Any image that 404s reveals the glyph via the
  CSP-safe `img-fallback` listener.

  Prerequisites are **read-only and purely informational** - the player
  never ticks them and the row shows no met/unmet indicator. Whether a
  station prereq is actually satisfied is reflected at the card level
  (the LOCKED badge and the disabled Upgrade button), not per row.
  """
  attr :req, :map, required: true

  def prereq_row(assigns) do
    ~H"""
    <li class="flex items-center justify-between gap-2 text-xs">
      <span class="flex items-center gap-2 min-w-0 flex-1">
        <span class="relative w-7 h-7 shrink-0 border border-line bg-ink-950 flex items-center justify-center overflow-hidden">
          <img
            :if={@req.image}
            src={@req.image}
            alt=""
            loading="lazy"
            class="w-full h-full object-contain img-fallback"
          />
          <span
            :if={@req.image}
            style="display:none;"
            class="absolute inset-0 flex items-center justify-center"
          >
            <.icon name={@req.fallback} class="w-4 h-4 text-fog-400" />
          </span>
          <.icon :if={!@req.image} name={@req.fallback} class="w-4 h-4 text-fog-400" />
        </span>
        <span class="text-fog-200 truncate">{@req.name}</span>
      </span>
      <span class="t-num text-amber shrink-0 ml-2">{@req.qty}</span>
    </li>
    """
  end

  attr :slug, :string, required: true
  attr :section, :string, required: true
  attr :title, :string, required: true
  attr :open, :boolean, default: false
  # Optional "done/total" progress readout shown next to the title, so a
  # player sees how close a section is without expanding it.
  attr :badge, :string, default: nil
  slot :inner_block, required: true

  def module_section(assigns) do
    ~H"""
    <div class="border border-line overflow-hidden">
      <button
        type="button"
        phx-click="toggle_section"
        phx-value-slug={@slug}
        phx-value-section={@section}
        aria-expanded={@open}
        class={[
          "w-full flex items-center justify-between gap-2 px-3 py-2.5 text-left t-label text-xs transition-colors hud-focus",
          "hover:bg-ink-900 hover:text-amber",
          if(@open, do: "text-fog-200", else: "text-fog-500")
        ]}
      >
        <span class="flex items-center gap-2">
          {@title}
          <span :if={@badge} class="t-num text-[10px] text-fog-500">{@badge}</span>
        </span>
        <.icon
          name="hero-chevron-down"
          class={[
            "w-4 h-4 transition-transform",
            if(@open, do: "text-fog-200", else: "text-fog-500"),
            @open && "rotate-180"
          ]}
        />
      </button>
      <%= if @open do %>
        <div class="px-3 py-3 border-t border-line">
          {render_slot(@inner_block)}
        </div>
      <% end %>
    </div>
    """
  end

  # ── Data adapters (DB → UI shape) ──────────────────────

  # Stash is the only module that can never be torn down past
  # level 1 - there's no "no stash" state in the game. We surface
  # this with a per-module `:min_level` so the rest of the LiveView
  # (clamp, downgrade visibility, button labels) can stay generic.
  @min_levels %{"stash" => 1}

  defp min_level_for(slug), do: Map.get(@min_levels, slug, 0)

  # Builds the initial list of module maps the template renders.
  # Most modules start at level 0; the per-slug `:min_level` map
  # above covers the exceptions (currently just Stash, which starts
  # at level 1 because the game gives every player a Stash by default).
  defp build_initial_modules do
    summaries = Hideout.list_modules()

    base =
      Enum.map(summaries, fn summary ->
        min_level = min_level_for(summary.slug)

        %{
          slug: summary.slug,
          name: summary.name,
          current: min_level,
          max: summary.max,
          min_level: min_level,
          # Derived from the tick set by recompute_statuses/2.
          status: :missing_prereqs,
          prerequisites: [],
          needed: [],
          # Populated only when the module is at max level. List of
          # `%{name, qty}` covering every item the user spent to build
          # this module up - sums quantities across all levels 1..max.
          items_used: []
        }
      end)

    # Deliberately NOT populated here. `mount/3` calls `apply_hideout_levels/2`
    # on the very next line, which re-derives every module's requirements from
    # the operator's persisted levels — so anything computed here is built and
    # then thrown away on every single mount. Returning the bare list halves the
    # work instead of relying on the cache to hide the duplication.
    #
    # The disconnected render assigns `[]`, so nothing renders these
    # unpopulated.
    base
  end

  # Populate `:prerequisites`, `:needed` and `:items_used` for every module in
  # `modules`, using ONE batched read for the whole set.
  #
  # `only` restricts which modules are recomputed (the level-change handlers
  # touch a single station) but not how the read is issued — that is always
  # batched, so there is no per-station fetch anywhere in this module to
  # accidentally reach for.
  #
  # Do not reintroduce a per-module fetch. 26 stations x (one query for the
  # level plus one per preloaded association) came to 155 queries and 7.1
  # SECONDS against a hosted database ~76ms away. Locally, against Postgres on
  # the same machine, the identical code costs ~50ms and looks perfectly fine —
  # which is precisely why it survived twice. `build_initial_modules/0` was
  # fixed the first time; `apply_hideout_levels/2` kept its own copy and was
  # reached on nearly every mount.
  #
  # `hideout_live_query_count_test.exs` fails if the query count starts scaling
  # with the number of stations, and runs with the cache OFF so it measures the
  # batching rather than a cache hiding the N+1.
  defp populate_all(modules, only \\ :all) do
    targets = Enum.filter(modules, &included?(&1, only))

    prefetched =
      targets
      |> Enum.reject(fn mod -> mod.current >= mod.max end)
      |> Enum.map(fn mod -> {mod.slug, mod.current + 1} end)
      |> Hideout.get_level_requirements_for()

    Enum.map(modules, fn mod ->
      if included?(mod, only) do
        mod
        |> populate_requirements(prefetched)
        |> populate_items_used()
      else
        mod
      end
    end)
  end

  defp included?(_mod, :all), do: true
  defp included?(mod, slugs) when is_list(slugs), do: mod.slug in slugs

  # Project the prefetched requirements for `current + 1` (the level the player
  # would build next) into the `:prerequisites` / `:needed` shape the template
  # expects. At max level both lists are empty since the template hides those
  # sections anyway.
  #
  # Takes the prefetched map rather than a slug, deliberately: there is no
  # single-module variant to fall back to, so reintroducing the N+1 would have
  # to be a visible change rather than a one-line slip.
  defp populate_requirements(%{current: current, max: max} = mod, _prefetched)
       when current >= max do
    %{mod | prerequisites: [], needed: []}
  end

  defp populate_requirements(mod, prefetched) do
    target_level = mod.current + 1

    case Map.get(prefetched, {mod.slug, target_level}) do
      nil ->
        %{mod | prerequisites: [], needed: []}

      reqs ->
        # Drop self-referential station-level requirements before
        # they reach the rest of the LiveView. The API faithfully
        # reports "Stash lvl 2 requires Stash lvl 1", but the
        # upgrade chain already implies that - showing it in the
        # Prerequisites list (and counting it for `prereqs_met?`)
        # is just noise.
        clean_station_reqs =
          Enum.reject(reqs.station_level_requirements, fn r ->
            r.required_station.normalized_name == mod.slug
          end)

        clean_reqs = %{reqs | station_level_requirements: clean_station_reqs}

        %{
          mod
          | prerequisites: build_prerequisites(clean_reqs),
            needed: build_needed(clean_reqs)
        }
    end
  end

  # Prerequisites = station level reqs + skill reqs + trader reqs.
  # Items go in `:needed` instead so the existing template renders them
  # as clickable links to the items page. Each prerequisite carries a
  # `:kind` plus either an `:image` (trader portrait from the API, or
  # the vendored station icon) or a heroicon `:fallback` glyph - skills
  # have no artwork from tarkov.dev, so they use the glyph.
  #
  # Prerequisites are read-only and purely informational in the UI - the
  # player never ticks them and we deliberately don't render a met/unmet
  # indicator on each row. Station prereqs still carry the structured
  # `:slug` / `:required_level` they resolve against, because
  # `station_prereqs_met?/2` uses them to gate the build against the
  # *actual* current level of the referenced module (which drives the
  # card-level LOCKED badge and the disabled Upgrade button).
  defp build_prerequisites(reqs) do
    station_reqs =
      Enum.map(reqs.station_level_requirements, fn r ->
        %{
          id: "p:station:#{r.required_station.normalized_name}:#{r.required_level}",
          kind: :station,
          name: r.required_station.name,
          qty: "Lvl #{r.required_level}",
          slug: r.required_station.normalized_name,
          required_level: r.required_level,
          image: "/images/hideout/#{r.required_station.normalized_name}.webp",
          fallback: "hero-home-modern"
        }
      end)

    skill_reqs =
      Enum.map(reqs.skill_requirements, fn r ->
        %{
          id: "p:skill:#{r.skill.name}:#{r.required_level}",
          kind: :skill,
          name: "#{r.skill.name} skill",
          qty: "Lvl #{r.required_level}",
          slug: nil,
          required_level: r.required_level,
          image: nil,
          fallback: "hero-academic-cap"
        }
      end)

    trader_reqs =
      Enum.map(reqs.trader_requirements, fn r ->
        %{
          id: "p:trader:#{r.trader.name}:#{r.required_level}",
          kind: :trader,
          name: r.trader.name,
          qty: "LL#{r.required_level}",
          slug: nil,
          required_level: r.required_level,
          image: r.trader.image_link,
          fallback: "hero-user-circle"
        }
      end)

    station_reqs ++ skill_reqs ++ trader_reqs
  end

  defp build_needed(reqs) do
    Enum.map(reqs.item_requirements, fn r ->
      %{
        id: "i:#{r.item.normalized_name}",
        name: r.item.name,
        qty: thousands(r.quantity),
        icon: r.item.icon_link
      }
    end)
  end

  # Populate the `:items_used` list. Only meaningful at max level; for
  # any other state we clear the list (a downgrade from max should
  # remove the cumulative-cost section). The cumulative cost is
  # computed by the context with a single grouped query, so this
  # stays cheap even when called on every level change.
  defp populate_items_used(%{current: current, max: max, slug: slug} = mod)
       when current >= max do
    rows = Hideout.get_total_item_cost(slug, max)

    items_used =
      Enum.map(rows, fn row ->
        %{name: row.item.name, qty: thousands(row.quantity), icon: row.item.icon_link}
      end)

    %{mod | items_used: items_used}
  end

  defp populate_items_used(mod), do: %{mod | items_used: []}

  # Display order: ready to build first, then "missing items"
  # (something the user can act on, just not finish), then locked
  # (waiting on prereqs), and finally maxed at the bottom - the user
  # asked for that order so the actionable cards float to the top of
  # the grid. Within each bucket we keep alphabetical order so the
  # arrangement is stable.
  defp sort_by_status(modules) do
    Enum.sort_by(modules, fn mod ->
      {status_sort_rank(module_status(mod)), mod.name}
    end)
  end

  defp status_sort_rank(:ready), do: 0
  defp status_sort_rank(:missing_items), do: 1
  defp status_sort_rank(:missing_prereqs), do: 2
  defp status_sort_rank(:max_level), do: 3

  # Sections whose open state means the user is actively working on a
  # module, and so its grid position should be pinned.
  @expandable_sections ~w(prerequisites needed items_used)

  # Whether a module currently has any section expanded (i.e. the user is
  # working on it and its position should hold still).
  defp module_expanded?(expanded, slug) do
    Enum.any?(@expandable_sections, &MapSet.member?(expanded, "#{slug}:#{&1}"))
  end

  # Re-sort the grid by status, but keep any module the user currently has
  # expanded pinned to its present index. Ticking the last needed item
  # flips a card to READY, which would otherwise jump it to the top of the
  # grid mid-interaction; pinning holds an expanded card in place until the
  # user collapses it - at which point `toggle_section` runs this again and
  # the now-unpinned card drops into its proper bucket. Non-expanded cards
  # still sort freely around the pinned ones.
  defp reorder_locking_expanded(modules, expanded) do
    pinned_by_index =
      modules
      |> Enum.with_index()
      |> Enum.filter(fn {mod, _i} -> module_expanded?(expanded, mod.slug) end)
      |> Map.new(fn {mod, i} -> {i, mod} end)

    if map_size(pinned_by_index) == 0 do
      sort_by_status(modules)
    else
      sorted_free =
        modules
        |> Enum.reject(&module_expanded?(expanded, &1.slug))
        |> sort_by_status()

      {result, _} =
        Enum.reduce(0..(length(modules) - 1), {[], sorted_free}, fn i, {acc, free} ->
          case Map.get(pinned_by_index, i) do
            nil ->
              [head | tail] = free
              {[head | acc], tail}

            mod ->
              {[mod | acc], free}
          end
        end)

      Enum.reverse(result)
    end
  end

  defp current_levels(modules) do
    Map.new(modules, &{&1.slug, &1.current})
  end
end
