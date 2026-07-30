defmodule EftBuddyWeb.AmmoLive.Index do
  @moduledoc """
  "Ammo / Ballistics" — a searchable ammunition chart grouped by caliber,
  modelled on the community EFT ballistics charts: alongside the raw
  stats, each round shows a colour-coded **penetration-vs-armor-class**
  matrix (Class 1–6, red = won't penetrate → green = penetrates
  reliably) so the raw penetration number has real context.

  Data comes from the `ammo` table (synced from the tarkov.dev JSON API by
  `EftBuddy.Ammo.Sync`). Rounds are grouped by caliber in one aligned
  table; every stat column is sortable, and the sort is scoped **within
  each caliber block** so reordering never scrambles the grouping. A single
  free-text search (name or caliber) is the only filter — it lives in the
  shared top-of-page controls bar alongside the ammo/plates view switch.
  """
  use EftBuddyWeb, :live_view

  alias EftBuddy.Ammo
  alias EftBuddy.Armor
  alias EftBuddy.Armor.Material

  # Below this muzzle velocity (m/s) a round is subsonic. Only meaningful
  # for actual projectiles, so we don't tag grenades / flares with it.
  @subsonic_threshold 343

  # Armor classes shown in the penetration matrix, low → high (C1 → C6).
  @armor_classes [1, 2, 3, 4, 5, 6]

  @impl true
  def mount(_params, _session, socket) do
    # Load the datasets only once the socket is live, so the disconnected
    # static render doesn't run the same queries a second time. Until then
    # the lists are empty and the template shows the shared standby panel.
    rounds = if connected?(socket), do: Ammo.list_rounds(), else: []
    plates = if connected?(socket), do: Armor.list_plates(), else: []

    {:ok,
     socket
     |> assign(:page_title, "Ballistics")
     |> assign(
       :page_description,
       "Escape from Tarkov ammo chart and body-armor plates: damage, penetration and a color-coded penetration-vs-armor-class matrix for every round."
     )
     |> assign(:active, :ammo)
     |> assign(:query, "")
     # Per-caliber sort state: %{caliber_enum => sort_atom}. Each ammo
     # block sorts independently; a caliber absent from the map is
     # `:default` (penetration power descending).
     |> assign(:sorts, %{})
     |> assign(:rounds, rounds)
     # Column colour ranges computed once from the *whole* round list (not the
     # filtered view), so the Armor / Ricochet gradients stay stable as the
     # operator searches. `{min, max}` per column.
     |> assign(:armor_range, value_range(rounds, & &1.armor_damage))
     |> assign(:ricochet_range, value_range(rounds, & &1.ricochet_chance))
     # A single view switch (ammo | plates) picks which dataset shows —
     # one view is always visible, so the page never reads as empty.
     |> assign(:view, :ammo)
     |> assign(:plates, plates)
     |> assign(:plates_count, length(plates))
     # Per-class sort state: %{class => sort_atom}. Each plate block sorts
     # independently, mirroring the ammo caliber blocks.
     |> assign(:plates_sorts, %{})
     # Colour ranges for the material-derived plate columns, over the whole
     # plate list so the Destructibility / Explosive gradients span green→red.
     |> assign(:destructibility_range, material_value_range(plates, &Material.destructibility/1))
     |> assign(
       :explosive_range,
       material_value_range(plates, &Material.explosive_destructibility/1)
     )
     # Derived views start empty; `apply_active_view/1` fills in whichever
     # one is on screen (ammo), leaving the hidden one to be built on demand.
     |> assign(:groups, [])
     |> assign(:total, 0)
     |> assign(:plate_groups, [])
     |> apply_active_view()}
  end

  # ── Events ─────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(:query, query |> to_string() |> String.slice(0, 100))
     |> apply_active_view()}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:query, "") |> apply_active_view()}
  end

  # Column-header sort toggle for a single caliber block (`<.sort_header>`
  # → 3-state). Scoped per caliber so reordering one block never touches
  # the others.
  def handle_event("toggle_sort", %{"col" => col, "caliber" => caliber}, socket) do
    current = Map.get(socket.assigns.sorts, caliber, :default)
    sorts = Map.put(socket.assigns.sorts, caliber, EftBuddyWeb.UI.next_sort(col, current))

    {:noreply, socket |> assign(:sorts, sorts) |> apply_ammo_view()}
  end

  # Column-header sort toggle for a single plate class block, scoped per
  # class (via `phx-value-class`) so reordering one block never touches
  # the others.
  def handle_event("toggle_plates_sort", %{"col" => col, "class" => class}, socket) do
    class = String.to_integer(class)
    current = Map.get(socket.assigns.plates_sorts, class, :default)
    sorts = Map.put(socket.assigns.plates_sorts, class, EftBuddyWeb.UI.next_sort(col, current))

    {:noreply, socket |> assign(:plates_sorts, sorts) |> apply_plates_view()}
  end

  # Primary view switch fired by the top `<.tabs>` strip (`filter` key):
  # "ammo" | "plates". Rebuild the newly-shown view so it reflects the
  # current search (it may have gone stale while the other view was active).
  def handle_event("set_view", %{"filter" => value}, socket),
    do: {:noreply, socket |> assign(:view, parse_view(value)) |> apply_active_view()}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── View assembly ──────────────────────────────────────

  # Rebuild whichever view is currently on screen. Search, clear and the
  # view switch all funnel through here, so only the visible table is
  # recomputed on a keystroke; the hidden view is left as-is until it's
  # shown (or its own sort toggle fires), at which point it's rebuilt
  # against the current search.
  defp apply_active_view(socket) do
    case socket.assigns.view do
      :ammo -> apply_ammo_view(socket)
      :plates -> apply_plates_view(socket)
    end
  end

  # Recompute the ammo view (grouped + sorted rounds + total) from the base
  # round list already held in the socket — no DB round-trip on filter/sort.
  defp apply_ammo_view(socket) do
    %{rounds: rounds, query: query, sorts: sorts} = socket.assigns

    filtered = Ammo.filter(rounds, %{query: query, caliber: "all", source: "all"})

    socket
    |> assign(:groups, Ammo.group(filtered, sorts))
    |> assign(:total, length(filtered))
  end

  # Recompute the plates grouped-by-class view from the base plate list in
  # the socket, honouring the current search + plate sort — no DB
  # round-trip on a filter/sort event.
  defp apply_plates_view(socket) do
    %{plates: plates, plates_sorts: sorts, query: query} = socket.assigns

    plate_groups =
      plates
      |> filter_plates(query)
      |> Armor.group_by_class(sorts)

    assign(socket, :plate_groups, plate_groups)
  end

  # Free-text plate filter (name / short name / material), mirroring the
  # ammo search so the shared search box works in both views.
  defp filter_plates(plates, query) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" -> plates
      needle -> Enum.filter(plates, &plate_match?(&1, needle))
    end
  end

  defp plate_match?(plate, needle) do
    [plate.item && plate.item.name, plate.item && plate.item.short_name, material_label(plate)]
    |> Enum.any?(fn field ->
      is_binary(field) and String.contains?(String.downcase(field), needle)
    end)
  end

  defp parse_view("plates"), do: :plates
  defp parse_view(_), do: :ammo

  # ── Function components ────────────────────────────────

  @doc false
  # One caliber's ammo table, in its own panel with its own sort header
  # row. The sort is scoped to this block via `phx-value-caliber`, so each
  # block reorders independently. `@sort` is this caliber's current sort
  # atom (`:default` when it hasn't been touched).
  attr :caliber, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true
  attr :sort, :atom, required: true
  attr :armor_range, :any, required: true
  attr :ricochet_range, :any, required: true

  def caliber_block(assigns) do
    ~H"""
    <section class="hud-panel overflow-hidden">
      <div class="flex items-center gap-3 px-5 py-3 border-b border-line bg-ink-900/60">
        <span class="t-head text-sm text-amber">{@label}</span>
        <span class="h-px flex-1 hud-rule"></span>
        <span class="t-label text-[9px] text-fog-500">{length(@rows)} rounds</span>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm border-collapse table-fixed min-w-312.5">
          <%!-- Ammo-name column widened (260 -> 300) and the two Bleeding
               columns trimmed (96 -> 80) to give the name + its label pills
               (Subsonic / tracer) room to sit on a single line. The Bleeding
               headers already wrap to two lines at this width, so trimming
               them costs nothing. C1-C6 stay at 44px. --%>
          <colgroup>
            <col style="width: 300px" />
            <col style="width: 66px" />
            <col style="width: 60px" />
            <col style="width: 74px" />
            <col style="width: 70px" />
            <col style="width: 72px" />
            <col style="width: 66px" />
            <col style="width: 68px" />
            <col style="width: 80px" />
            <col style="width: 80px" />
            <col style="width: 56px" />
            <col :for={_c <- armor_classes()} style="width: 44px" />
          </colgroup>

          <thead>
            <tr class="border-b border-line">
              <th class="text-left px-5 py-2 sticky left-0 z-20 bg-ink-850 border-r border-line">
                <.sort_header
                  label="Ammo"
                  col="name"
                  sort={@sort}
                  asc={:name_asc}
                  desc={:name_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Dmg"
                  col="damage"
                  sort={@sort}
                  asc={:damage_asc}
                  desc={:damage_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Pen"
                  col="pen"
                  sort={@sort}
                  asc={:pen_asc}
                  desc={:pen_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Armor"
                  col="armor"
                  sort={@sort}
                  asc={:armor_asc}
                  desc={:armor_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Ricochet"
                  col="ricochet"
                  sort={@sort}
                  asc={:ricochet_asc}
                  desc={:ricochet_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Accuracy"
                  col="accuracy"
                  sort={@sort}
                  asc={:accuracy_asc}
                  desc={:accuracy_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Recoil"
                  col="recoil"
                  sort={@sort}
                  asc={:recoil_asc}
                  desc={:recoil_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Velocity"
                  col="velocity"
                  sort={@sort}
                  asc={:velocity_asc}
                  desc={:velocity_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Light Bleeding"
                  col="light_bleed"
                  sort={@sort}
                  asc={:light_bleed_asc}
                  desc={:light_bleed_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Heavy Bleeding"
                  col="heavy_bleed"
                  sort={@sort}
                  asc={:heavy_bleed_asc}
                  desc={:heavy_bleed_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Stack"
                  col="stack"
                  sort={@sort}
                  asc={:stack_asc}
                  desc={:stack_desc}
                  phx-value-caliber={@caliber}
                />
              </th>
              <th
                :for={c <- armor_classes()}
                class={[
                  "text-center px-0 py-2 t-num text-[10px] text-fog-500 font-normal",
                  c == 1 && "border-l border-line"
                ]}
                title={"Armor class #{c}"}
              >
                C{c}
              </th>
            </tr>
          </thead>

          <tbody>
            <tr
              :for={a <- @rows}
              class="border-b border-line/60 bg-ink-850 hover:bg-ink-900 transition-colors"
            >
              <td class="px-5 py-2 sticky left-0 z-10 bg-inherit border-r border-line">
                <div class="flex items-center gap-2.5 min-w-0">
                  <.item_tile :if={a.item} item={a.item} size="w-9 h-9" />
                  <div class="min-w-0">
                    <div class="text-fog-100 font-medium truncate">{ammo_name(a)}</div>
                    <div
                      :if={(a.item && a.item.short_name) || subsonic?(a) || a.tracer}
                      class="flex items-center gap-1.5 mt-1"
                    >
                      <span
                        :if={a.item && a.item.short_name}
                        class="t-label text-[9px] text-fog-500 truncate"
                      >
                        {a.item.short_name}
                      </span>
                      <span
                        :if={subsonic?(a)}
                        class="t-label text-[10px] px-1.5 py-0.5 rounded-sm border inline-block leading-none whitespace-nowrap bg-ink-950 text-fog-400 border-line-strong"
                      >
                        Subsonic
                      </span>
                      <span
                        :if={a.tracer}
                        class="t-label text-[10px] px-1.5 py-0.5 rounded-sm border inline-block leading-none whitespace-nowrap bg-ink-950 text-fog-400 border-line-strong"
                      >
                        {tracer_label(a.tracer_color)}
                      </span>
                    </div>
                  </div>
                </div>
              </td>
              <td class="px-3 py-2 text-left t-num text-fog-200 whitespace-nowrap">
                {a.damage}<span
                  :if={a.projectile_count > 1}
                  class="text-fog-500 text-[11px]"
                > ×{a.projectile_count}</span>
              </td>
              <td class="px-3 py-2 text-left t-num text-fog-200">{a.penetration_power}</td>
              <td
                class="px-3 py-2 text-left t-num"
                style={"color: #{range_color(a.armor_damage, @armor_range, :high_good)}"}
              >
                {a.armor_damage}%
              </td>
              <td
                class="px-3 py-2 text-left t-num"
                style={"color: #{range_color(a.ricochet_chance, @ricochet_range, :low_good)}"}
              >
                {fmt_pct(a.ricochet_chance)}
              </td>
              <td class={["px-3 py-2 text-left t-num", modifier_class(a.accuracy_modifier)]}>
                {fmt_modifier(a.accuracy_modifier)}
              </td>
              <td class={["px-3 py-2 text-left t-num", modifier_class_inverted(a.recoil_modifier)]}>
                {fmt_modifier(a.recoil_modifier)}
              </td>
              <td class="px-3 py-2 text-left t-num text-fog-300 whitespace-nowrap">
                {fmt_velocity(a.initial_speed)}<span class="text-fog-600 text-[10px]"> m/s</span>
              </td>
              <td class={[
                "px-3 py-2 text-left t-num",
                modifier_class(a.light_bleed_modifier)
              ]}>
                {fmt_modifier(a.light_bleed_modifier)}
              </td>
              <td class={[
                "px-3 py-2 text-left t-num",
                modifier_class(a.heavy_bleed_modifier)
              ]}>
                {fmt_modifier(a.heavy_bleed_modifier)}
              </td>
              <td class="px-3 py-2 text-left t-num text-fog-300">{a.stack_max_size}</td>
              <td
                :for={c <- armor_classes()}
                class={["px-0.5 py-2 text-center", c == 1 && "border-l border-line/40"]}
              >
                <span
                  class="inline-flex items-center justify-center w-7 h-7 t-num text-[11px] text-fog-50 border border-black/25 cursor-help"
                  style={"background-color: #{class_pen_color(a, c)}"}
                  data-pen-rating={class_rating(a, c)}
                  aria-label={"Class #{c}: #{rating_label(class_rating(a, c))}"}
                >
                  {class_rating(a, c)}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  @doc false
  # One protection class's plate table, in its own panel with its own sort
  # header row (scoped via `phx-value-class`), mirroring `caliber_block/1`.
  attr :class, :integer, required: true
  attr :plates, :list, required: true
  attr :sort, :atom, required: true
  attr :destructibility_range, :any, required: true
  attr :explosive_range, :any, required: true

  def plate_block(assigns) do
    ~H"""
    <section class="hud-panel overflow-hidden">
      <div class="flex items-center gap-3 px-5 py-3 border-b border-line bg-ink-900/60">
        <span class="t-head text-sm text-amber">Class {@class}</span>
        <span class="h-px flex-1 hud-rule"></span>
        <span class="t-label text-[9px] text-fog-500">{length(@plates)} plates</span>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm border-collapse table-fixed min-w-286">
          <colgroup>
            <col style="width: 260px" />
            <col style="width: 112px" />
            <col style="width: 108px" />
            <col style="width: 96px" />
            <col style="width: 64px" />
            <col style="width: 84px" />
            <col style="width: 100px" />
            <col style="width: 64px" />
            <col style="width: 64px" />
            <col style="width: 60px" />
            <col style="width: 60px" />
            <col style="width: 72px" />
          </colgroup>
          <thead>
            <tr class="border-b border-line">
              <th class="text-left px-5 py-2 sticky left-0 z-20 bg-ink-850 border-r border-line">
                <.sort_header
                  label="Plate"
                  col="plate"
                  sort={@sort}
                  asc={:plate_asc}
                  desc={:plate_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Material"
                  col="material"
                  sort={@sort}
                  asc={:material_asc}
                  desc={:material_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Destructibility"
                  col="destructibility"
                  sort={@sort}
                  asc={:destructibility_asc}
                  desc={:destructibility_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Explosive"
                  col="explosive"
                  sort={@sort}
                  asc={:explosive_asc}
                  desc={:explosive_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Type"
                  col="type"
                  sort={@sort}
                  asc={:type_asc}
                  desc={:type_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Durability"
                  col="durability"
                  sort={@sort}
                  asc={:durability_asc}
                  desc={:durability_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Eff. Durability"
                  col="eff_dur"
                  sort={@sort}
                  asc={:eff_dur_asc}
                  desc={:eff_dur_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Blunt"
                  col="blunt"
                  sort={@sort}
                  asc={:blunt_asc}
                  desc={:blunt_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Speed"
                  col="speed"
                  sort={@sort}
                  asc={:speed_asc}
                  desc={:speed_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Turn"
                  col="turn"
                  sort={@sort}
                  asc={:turn_asc}
                  desc={:turn_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Ergo"
                  col="ergo"
                  sort={@sort}
                  asc={:ergo_asc}
                  desc={:ergo_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
              <th class="text-left px-3 py-2">
                <.sort_header
                  label="Repair"
                  col="repair"
                  sort={@sort}
                  asc={:repair_asc}
                  desc={:repair_desc}
                  event="toggle_plates_sort"
                  phx-value-class={@class}
                />
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={p <- @plates}
              class="border-b border-line/60 bg-ink-850 hover:bg-ink-900 transition-colors"
            >
              <td class="px-5 py-2 sticky left-0 z-10 bg-inherit border-r border-line">
                <div class="flex items-center gap-2.5 min-w-0">
                  <.item_tile :if={p.item} item={p.item} size="w-9 h-9" />
                  <div class="min-w-0">
                    <div class="text-fog-100 font-medium truncate">{plate_name(p)}</div>
                    <div
                      :if={p.item && p.item.short_name}
                      class="t-label text-[9px] text-fog-500 truncate mt-1"
                    >
                      {p.item.short_name}
                    </div>
                  </div>
                </div>
              </td>
              <td class="px-3 py-2 text-left text-fog-300 truncate">{material_label(p)}</td>
              <td class="px-3 py-2 text-left t-num">
                <span
                  :if={plate_destructibility(p)}
                  style={"color: #{range_color(plate_destructibility(p), @destructibility_range, :low_good)}"}
                >
                  {plate_destructibility(p)}
                </span>
                <span :if={!plate_destructibility(p)} class="text-fog-600">-</span>
              </td>
              <td class="px-3 py-2 text-left t-num">
                <span
                  :if={plate_explosive_destructibility(p)}
                  style={"color: #{range_color(plate_explosive_destructibility(p), @explosive_range, :low_good)}"}
                >
                  {plate_explosive_destructibility(p)}
                </span>
                <span :if={!plate_explosive_destructibility(p)} class="text-fog-600">-</span>
              </td>
              <td class="px-3 py-2 text-left text-fog-300">{p.armor_type}</td>
              <td class="px-3 py-2 text-left t-num text-fog-300">{p.durability}</td>
              <td class="px-3 py-2 text-left t-num text-fog-100">
                {effective_durability(p)}
              </td>
              <td class="px-3 py-2 text-left t-num text-fog-300">
                {fmt_pct(p.blunt_throughput)}
              </td>
              <td class={["px-3 py-2 text-left t-num", modifier_class(p.speed_penalty)]}>
                {fmt_modifier(p.speed_penalty)}
              </td>
              <td class={["px-3 py-2 text-left t-num", modifier_class(p.turn_penalty)]}>
                {fmt_modifier(p.turn_penalty)}
              </td>
              <td class={["px-3 py-2 text-left t-num", modifier_class(p.ergo_penalty)]}>
                {fmt_modifier(p.ergo_penalty)}
              </td>
              <td class="px-3 py-2 text-left t-num text-fog-300">{p.repair_cost}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # ── Presentation helpers (used by the template) ────────

  @doc false
  def armor_classes, do: @armor_classes

  @doc false
  # Display name for a round, read from its linked item. Falls back to a
  # placeholder if the item link hasn't resolved yet (item_id null).
  def ammo_name(%{item: %{name: name}}) when is_binary(name), do: name
  def ammo_name(_), do: "Unknown round"

  @doc false
  # Notes on whether a round is worth flagging beyond the numeric columns.
  def subsonic?(%{ammo_type: type, initial_speed: speed})
      when type in ["bullet", "buckshot"] and is_number(speed),
      do: speed > 0 and speed < @subsonic_threshold

  def subsonic?(_), do: false

  @doc false
  # Signed-percentage rendering for a fractional modifier (accuracy,
  # recoil, bleed). `0` renders as a dim dash — most rounds are `0` and a
  # wall of "+0%" is noise.
  def fmt_modifier(value) when is_number(value) do
    pct = round(value * 100)

    cond do
      pct > 0 -> "+#{pct}%"
      pct < 0 -> "#{pct}%"
      true -> "-"
    end
  end

  def fmt_modifier(_), do: "-"

  @doc false
  # Tailwind text-colour class for a signed modifier: green when the value
  # helps (positive), red when it hurts (negative), dim when it's zero.
  def modifier_class(value) when is_number(value) do
    cond do
      value > 0 -> "text-go"
      value < 0 -> "text-rust"
      true -> "text-fog-600"
    end
  end

  def modifier_class(_), do: "text-fog-600"

  @doc false
  # Inverted `modifier_class/1`, for stats where a positive value is the
  # harmful one (recoil): positive → red, negative → green, zero → dim.
  def modifier_class_inverted(value) when is_number(value) do
    cond do
      value > 0 -> "text-rust"
      value < 0 -> "text-go"
      true -> "text-fog-600"
    end
  end

  def modifier_class_inverted(_), do: "text-fog-600"

  @doc false
  # A 0–1 probability rendered as a whole percentage (e.g. `0.5 -> "50%"`).
  def fmt_pct(value) when is_number(value), do: "#{round(value * 100)}%"
  def fmt_pct(_), do: "-"

  @doc false
  # Muzzle velocity as a rounded integer m/s.
  def fmt_velocity(value) when is_number(value), do: round(value)
  def fmt_velocity(_), do: "-"

  @doc false
  # Pill label for a tracer round — names the tracer colour (e.g.
  # "Red Tracer"), matching how the in-game round is described.
  def tracer_label(color) when is_binary(color) and color != "",
    do: "#{String.capitalize(color)} Tracer"

  def tracer_label(_), do: "Tracer"

  # ── Armor plate helpers (Plates block) ─────────────────

  @doc false
  # Plate display name, read from its linked item.
  def plate_name(%{item: %{name: name}}) when is_binary(name), do: name
  def plate_name(_), do: "Unknown plate"

  @doc false
  # Toughness metric = durability / material destructibility.
  def effective_durability(plate),
    do: Material.effective_durability(plate.durability, plate.material)

  @doc false
  # Human material label (e.g. "Armored Steel").
  def material_label(plate), do: Material.label(plate.material)

  @doc false
  # Bullet-hit destructibility factor for a plate's material (nil if unknown).
  def plate_destructibility(plate), do: Material.destructibility(plate.material)

  @doc false
  # Explosive destructibility factor for a plate's material (nil if unknown).
  def plate_explosive_destructibility(plate),
    do: Material.explosive_destructibility(plate.material)

  # ── Penetration vs armor class (NoFoodAfterMidnight tiers) ─────
  #
  # The colour matrix rates each round 0–6 against every armor class,
  # matching the community "NoFoodAfterMidnight" effectiveness tiers the
  # official wiki's Ballistics table uses:
  #
  #   6  Usually ignores      penetrates >80% of the time on the first hit
  #   5  Very effective       penetrates a large % initially, quickly >90%
  #   4  Effective            low–medium chance that climbs quickly
  #   3  Slightly effective   low chance that slowly climbs / grinds through
  #   2  Magdump only         very low chance, very slowly gains
  #   1  It's possible, but…  barely penetrates for a long time
  #   0  Pointless            can't penetrate in any reasonable # of hits
  #
  # There is no official BSG per-hit penetration-chance formula, and the
  # real "average shots to penetrate" the wiki rates depends on BOTH
  # penetration power AND armor damage (the plate degrades as it soaks
  # hits). Rather than fake a shot-by-shot sim, these per-class thresholds
  # were fit directly to the published eft-ammo / wiki ratings for the
  # whole catalogue (~186 rounds): `@pen_thresholds[class]` is the minimum
  # penetration power a round needs to reach rating 1, 2, … 6 against that
  # class. Fitting to the source reproduces it to ~88% exact / ~97% within
  # one tier, and matches the iconic rounds (M855A1, M995, M61, BP, …)
  # exactly.
  #
  # One special case the thresholds can't express: true buckshot fires
  # many low-pen pellets that grind any plate down, so the wiki rates it a
  # flat 3 against every class — handled directly below.

  # Minimum penetration power to reach rating 1..6 against each armor
  # class, fit to the eft-ammo / wiki dataset.
  @pen_thresholds %{
    1 => [3, 4, 6, 7, 8, 10],
    2 => [10, 13, 14, 15, 16, 20],
    3 => [16, 20, 21, 23, 27, 30],
    4 => [21, 24, 29, 31, 35, 39],
    5 => [27, 30, 32, 36, 43, 49],
    6 => [31, 35, 39, 43, 47, 59]
  }

  @doc """
  Effectiveness rating (0–6) of a round against a fresh armor `class`
  (1–6). `ammo_type` lets us special-case true buckshot (a flat 3, since
  its pellets grind any plate down regardless of penetration); every other
  round is rated from its penetration power against `@pen_thresholds`.
  """
  def pen_rating(pen, ammo_type, class)
      when is_integer(pen) and is_integer(class) do
    if ammo_type == "buckshot" and pen <= 5 do
      3
    else
      rating_from_pen(pen, class)
    end
  end

  def pen_rating(_pen, _ammo_type, _class), do: 0

  defp rating_from_pen(pen, class) do
    case Map.fetch(@pen_thresholds, class) do
      {:ok, thresholds} ->
        Enum.reduce(1..6, 0, fn tier, best ->
          if pen >= Enum.at(thresholds, tier - 1), do: tier, else: best
        end)

      :error ->
        0
    end
  end

  @doc """
  Rating of `round` (an ammo struct) against `class` — reads the
  penetration power and ammo type off the struct.
  """
  def class_rating(round, class),
    do: pen_rating(round.penetration_power, round.ammo_type, class)

  @doc "Full effectiveness label for a 0–6 rating (NoFoodAfterMidnight tiers)."
  def rating_label(6), do: "Usually ignores"
  def rating_label(5), do: "Very effective"
  def rating_label(4), do: "Effective"
  def rating_label(3), do: "Slightly effective"
  def rating_label(2), do: "Magdump only"
  def rating_label(1), do: "It's possible, but..."
  def rating_label(_), do: "Pointless"

  @doc "Background hex colour for a 0–6 rating, red (low) → green (high)."
  # A single continuous red → green ramp. Every swatch shares the same
  # saturation and lightness (HSL S≈52% L≈37%) and only the hue rotates
  # (~4° red → ~132° green in even steps), so the scale reads as one smooth
  # gradient with no swatch — 4 and 5 included — jumping brighter or duller
  # than its neighbours.
  def rating_color(6), do: "#2d8f41"
  def rating_color(5), do: "#4e8f2d"
  def rating_color(4), do: "#7c8f2d"
  def rating_color(3), do: "#8f7f2d"
  def rating_color(2), do: "#8f632d"
  def rating_color(1), do: "#8f4b2d"
  def rating_color(_), do: "#8f342d"

  @doc "Background colour for a round's penetration vs a given armor class."
  def class_pen_color(round, class), do: rating_color(class_rating(round, class))

  @doc false
  # Legend swatches, weakest → strongest so the scale reads left→right
  # (red = low → green = high): {rating, label}.
  def pen_legend, do: Enum.map(0..6, &{&1, rating_label(&1)})

  # Value gradient anchors: green (good) → yellow (mid) → red (bad), taken
  # from the app's go / warn / rust status palette as {r, g, b}. Interpolated
  # continuously (see `range_color/3`) so a column's extremes land on pure
  # green / pure red.
  @grad_good {0x6C, 0xAE, 0x5A}
  @grad_mid {0xD8, 0xB5, 0x3F}
  @grad_bad {0xC0, 0x53, 0x3C}

  @doc false
  # `{min, max}` of a numeric field across a round list, ignoring non-numbers.
  # `{0, 0}` when there's nothing numeric to measure (e.g. the pre-connect
  # empty list), which `range_color/3` treats as "no gradient".
  def value_range(rounds, fun) do
    minmax(Enum.map(rounds, fun))
  end

  # `{min, max}` of a per-material figure across the plate list, skipping
  # plates whose material has no value for `fun`.
  defp material_value_range(plates, fun) do
    minmax(Enum.map(plates, &fun.(&1.material)))
  end

  defp minmax(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> {0, 0}
      nums -> {Enum.min(nums), Enum.max(nums)}
    end
  end

  @doc """
  Colour a numeric stat on a continuous green → yellow → red gradient,
  positioned by where `value` sits across the whole column's `{min, max}`
  range. Because it interpolates (rather than snapping to fixed buckets or
  thresholds), the column's best value lands on pure green and its worst on
  pure red, with a smooth spread between — so the full green→red range is
  actually used even when values bunch up. `dir` sets which end is green:
  `:low_good` (low = green) or `:high_good` (high = green). A constant column
  (min == max) or a non-numeric value gets the neutral fog colour.
  """
  def range_color(value, {min, max}, dir)
      when is_number(value) and is_number(min) and is_number(max) and max > min do
    frac = (value - min) / (max - min)
    # t: 0 = the "good" (green) end, 1 = the "bad" (red) end.
    t = if dir == :high_good, do: 1.0 - frac, else: frac
    gradient_hex(t)
  end

  def range_color(_value, _range, _dir), do: "#bcb9a6"

  # Continuous green → yellow → red interpolation for `t` in [0.0, 1.0].
  defp gradient_hex(t) do
    t = t |> max(0.0) |> min(1.0)

    {r, g, b} =
      if t <= 0.5,
        do: lerp_rgb(@grad_good, @grad_mid, t / 0.5),
        else: lerp_rgb(@grad_mid, @grad_bad, (t - 0.5) / 0.5)

    "#" <> hex2(r) <> hex2(g) <> hex2(b)
  end

  defp lerp_rgb({r1, g1, b1}, {r2, g2, b2}, f) do
    {round(r1 + (r2 - r1) * f), round(g1 + (g2 - g1) * f), round(b1 + (b2 - b1) * f)}
  end

  defp hex2(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

  # Removed: the raw penetration-power chip is no longer colour-coded — the
  # Class 1–6 matrix is the sole penetration colour cue now.
end
