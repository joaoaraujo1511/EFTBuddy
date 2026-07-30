defmodule EftBuddyWeb.OperatorState do
  @moduledoc """
  Shared "operator" state injected into every LiveView via `on_mount`.

  The OPERATOR HUD (left rail) is owned by the player, not the page: PMC level,
  scav karma, game mode (PVP/PVE) and faction (USEC/BEAR), plus the rail's
  collapsed state. This hook reads those values from the operator's
  `EftBuddy.OperatorSession` - the server-side authority for the connection -
  so the **first render of every mount is already correct**, including a
  `<.link navigate>` live navigation.

  ## Why it reads from a process and not the session

  A live navigation dismounts one LiveView and mounts the next over the same
  socket, and `on_mount` then runs against the socket's *connect-time* session:
  a snapshot frozen when the WebSocket connected, which no later cookie write
  can refresh. Hydrating prefs from that snapshot meant any change the operator
  had made since connecting was invisible to the next page, so the HUD rendered
  stale values and then visibly snapped to the right ones once a client
  round-trip corrected it.

  Reading from the session process removes the round-trip - and therefore the
  flash - entirely. See `EftBuddy.OperatorSession` for the ownership model, and
  `EftBuddyWeb.ClientBridge` for the (now cold-boot only) client transport.

  ## Assigns provided to every LiveView

    * `:pmc_level`      - integer 1..79 (per mode)
    * `:mode`           - `:pvp` | `:pve`
    * `:faction`        - `:usec` | `:bear` (per mode)
    * `:scav_karma`     - float -6.0..6.0 (per mode; stored internally in
                          hundredths, see `EftBuddy.Operator`)
    * `:rail_collapsed` - boolean (left nav rail collapsed to icons)
    * `:operator_token` - this browser's session token (used by the bridge)
    * `:operator_prefs` - the *whole* nested pref set, both modes' slices
                          included. Pages should read the flat assigns above;
                          this is here so a pref write can be folded into the
                          complete set the session and cookie need.
    * `:client_state`   - the operator's progress blob (watchlists, completed
                          tasks), namespaced per game mode - see
                          `EftBuddy.Progress`. Populated **before first render**
                          whenever the session already holds it, which is what
                          stops watchlists flashing empty on navigation.
    * `:progress_seeded?` - whether the *browser* has handed its `localStorage`
                          up to this session yet. False means `:client_state` is
                          the server's guess rather than the durable copy, and
                          `EftBuddyWeb.ClientBridge.put_progress/2` withholds its
                          `eft:store` push until it is true.

  ## Per-mode prefs

  PVP and PVE are separate progressions, so `:pmc_level`, `:scav_karma` and
  `:faction` are stored once per mode and the flat assigns above always describe
  the *active* one. A page therefore never has to know about the namespacing -
  but it does have to re-derive anything it caches from `:client_state` when it
  receives `{:sidebar_state_changed, :mode, _}`, because the operator's progress
  swapped underneath it.

  ## Events handled (attached as a `handle_event` hook)

    * `"pmc_level_inc"` / `"pmc_level_dec"` / `"set_pmc_level"`
    * `"scav_karma_inc"` / `"scav_karma_dec"` / `"set_scav_karma"`
    * `"set_mode"` / `"set_faction"`
    * `"toggle_rail"`

  Each writes through to the session process (authority), echoes to the browser
  via `push_event("eft:cookie", ...)` (durable backup) and, for page-derived
  keys, messages the LiveView with `{:sidebar_state_changed, key, value}` so
  pages that filter on the HUD can reflow.

  ## Cross-tab convergence

  The hook subscribes to the operator's topic, so a change made in one tab is
  applied to every other open tab. Broadcasts carry the originating pid and the
  originator skips its own echo, since it already applied the change locally.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias EftBuddy.Operator
  alias EftBuddy.OperatorSessions
  alias EftBuddyWeb.Plugs.OperatorSession, as: SessionPlug

  # Keys the pages derive content from. A change to one of these is announced
  # with `{:sidebar_state_changed, ...}`; pure chrome (`:rail_collapsed`) is
  # not, because no page filters on it and some pages only match known keys.
  @page_derived_keys [:pmc_level, :mode, :faction, :scav_karma]

  def on_mount(:default, _params, session, socket) do
    token = session[SessionPlug.token_key()]
    seed_prefs = session[SessionPlug.prefs_key()] || %{}

    # Authoritative read. On a cold boot this also creates the session and seeds
    # it from the bridged cookie; on every later mount (including a live
    # navigation) it returns the operator's current, post-interaction values.
    #
    # `create` is gated on a live socket: the static render can read the cookie
    # directly, so it needs no process, and a crawler that never opens a socket
    # allocates nothing.
    %{prefs: prefs, progress: progress, progress_seeded?: seeded?} =
      OperatorSessions.snapshot(token, seed_prefs: seed_prefs, create: connected?(socket))

    # Converge this tab with the operator's other tabs. Guarded on the token
    # because a LiveView mounted outside the `:browser` pipeline has none, and
    # the HUD must still render (with defaults) rather than crash the mount.
    if connected?(socket) and is_binary(token), do: OperatorSessions.subscribe(token)

    socket =
      socket
      |> assign(:operator_token, token)
      |> assign(:operator_prefs, prefs)
      |> assign_prefs(prefs)
      |> assign(:client_state, progress)
      # Whether the BROWSER has handed its `localStorage` up to this session yet.
      # False means `:client_state` is the server's guess, not the durable copy,
      # and `EftBuddyWeb.ClientBridge.put_progress/2` must not push over
      # `localStorage` until the browser has spoken - see there for why.
      |> assign(:progress_seeded?, seeded?)
      |> attach_hook(:operator_events, :handle_event, &handle_event/3)
      |> attach_hook(:operator_broadcasts, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  # NO `:nav_counts` ASSIGN, and none should come back without the pills that
  # consumed it. `EftBuddy.Stats.nav_counts/0` ran six `COUNT(*)` queries here, on
  # EVERY connected mount — which, because every route lives in one `live_session`,
  # means every `<.link navigate>` too. Commit `c13bdb2` removed both
  # `<.count_pill>` consumers and orphaned the producer, so for its whole remaining
  # life it was six round trips per navigation for a value nothing rendered.
  #
  # The audit prescribed caching it in `:persistent_term` with invalidation off the
  # sync telemetry. Deleting it removes the same cost with no cache, no invalidation
  # hook and no cold-read semantics to reason about — and it retired the inverted
  # `is_quest_item` partial index finding along with it, since `nav_counts/0` was
  # that index's only consumer.
  #
  # If the pills return, the counts want a cache, not a query per mount.

  # Flatten the pref set into one assign per pref key. Per-mode keys resolve
  # against the ACTIVE mode (`Operator.active/1`), which is what lets the HUD and
  # every page keep reading a plain `@pmc_level` while the value itself is
  # stored per game mode.
  defp assign_prefs(socket, prefs) do
    Enum.reduce(Operator.active(prefs), socket, fn {key, value}, acc ->
      assign(acc, key, assign_value(key, value))
    end)
  end

  # Karma is stored in integer hundredths but rendered as a float, so the
  # template and the Tasks page keep working with a plain number.
  defp assign_value(:scav_karma, cents), do: Operator.karma_to_float(cents)
  defp assign_value(_key, value), do: value

  # ── HUD events ─────────────────────────────────────────────────────

  defp handle_event("pmc_level_inc", _params, socket) do
    {:halt, put_pref(socket, :pmc_level, Operator.step_level(socket.assigns.pmc_level, :up))}
  end

  defp handle_event("pmc_level_dec", _params, socket) do
    {:halt, put_pref(socket, :pmc_level, Operator.step_level(socket.assigns.pmc_level, :down))}
  end

  defp handle_event("set_pmc_level", %{"pmc_level" => value}, socket) do
    {:halt, put_pref(socket, :pmc_level, value)}
  end

  defp handle_event("scav_karma_inc", _params, socket) do
    {:halt, put_pref(socket, :scav_karma, step_karma(socket, :up))}
  end

  defp handle_event("scav_karma_dec", _params, socket) do
    {:halt, put_pref(socket, :scav_karma, step_karma(socket, :down))}
  end

  defp handle_event("set_scav_karma", %{"scav_karma" => value}, socket) do
    {:halt, put_pref(socket, :scav_karma, value)}
  end

  defp handle_event("set_mode", %{"mode" => value}, socket) do
    {:halt, put_pref(socket, :mode, value)}
  end

  defp handle_event("set_faction", %{"faction" => value}, socket) do
    {:halt, put_pref(socket, :faction, value)}
  end

  defp handle_event("toggle_rail", _params, socket) do
    {:halt, put_pref(socket, :rail_collapsed, !socket.assigns.rail_collapsed)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # The assign is a float; stepping happens in canonical hundredths so repeated
  # nudges can't drift.
  defp step_karma(socket, direction) do
    socket.assigns.scav_karma
    |> then(&Operator.parse(:scav_karma, &1))
    |> Operator.step_karma(direction)
    |> Operator.karma_to_float()
  end

  # Write through to the authority, then reflect the canonical result locally.
  # An invalid or unchanged value (a cleared input mid-type, a repeated click at
  # the clamp) is a no-op: no assign churn, no cookie write, no page reflow.
  #
  # `:seed_prefs` carries the state currently on screen, so if the session has
  # idled out the write restarts it from what the operator can see rather than
  # from bare defaults - otherwise changing one pref would silently reset the
  # others on the next navigation.
  #
  # KNOWN GAP, deliberately not fixed here. `on_mount` seeds a session it creates
  # from `session[prefs_key()]`, which is the CONNECT-TIME snapshot frozen when
  # the page was rendered - a socket rejoin reuses the same signed session token,
  # so it does not refresh. On a rejoin whose session had died (>4h idle, crash,
  # deploy) the HUD therefore comes back showing the page-load values, and this
  # function then writes that reverted set back over the `eft_prefs` cookie, which
  # is the durable copy. Pref changes made in that tab after page load are lost.
  #
  # It is the same shape as the progress bug that `EftBuddyWeb.ClientBridge` now
  # guards against, but bounded to five small values the operator can re-set in a
  # click, and self-healing on the next full page load (which reads the real
  # cookie). It is NOT fixed the same way because prefs have no equivalent of
  # `:progress_seeded?`: a session found alive may legitimately never have been
  # spoken to by the browser, so the progress flag is not a sound proxy for "these
  # prefs may be stale", and suppressing the cookie write on that signal would
  # stop persisting pref changes in a common, healthy case. The fix wants its own
  # seeded-ness signal plus a client re-push on `reconnected()` - a parallel
  # seeding protocol, which does not belong bolted onto a data-loss fix. Tracked
  # for the observability/hardening pass.
  defp put_pref(socket, key, value) do
    opts = [seed_prefs: visible_prefs(socket)]

    case OperatorSessions.put_pref(socket.assigns.operator_token, key, value, opts) do
      {:ok, prefs} -> apply_prefs(socket, prefs)
      :unchanged -> socket
    end
  end

  # The operator's prefs in the shape `Operator.parse_all/1` accepts - i.e. the
  # cookie payload. Deliberately not the internal map: karma is integer
  # hundredths internally but karma units on the way in, so round-tripping the
  # internal value through `parse/2` would multiply it by 100.
  defp visible_prefs(socket) do
    Operator.cookie_payload(socket.assigns.operator_prefs)
  end

  # Apply a whole canonical pref set: re-derive every flat assign from it,
  # persist it to the browser's cookie as the cold-boot backup, and tell the page
  # to reflow for whichever page-derived values actually moved.
  #
  # This takes the full set rather than one key because a `:mode` flip changes
  # level, karma and faction too - they live in the mode's slice.
  #
  # `persist?` is false when we're applying another tab's broadcast: that tab
  # already wrote the cookie, and every tab issuing its own write would race for
  # no benefit.
  defp apply_prefs(socket, prefs, persist? \\ true) do
    changed = changed_page_keys(socket, prefs)

    socket =
      socket
      |> assign(:operator_prefs, prefs)
      |> assign_prefs(prefs)

    announce(socket, changed)

    if persist? do
      push_event(socket, "eft:cookie", Operator.cookie_payload(prefs))
    else
      socket
    end
  end

  # Which page-derived assigns this pref set actually changes. Compared against
  # the socket's CURRENT assigns, before they're overwritten.
  defp changed_page_keys(socket, prefs) do
    active = Operator.active(prefs)

    Enum.filter(@page_derived_keys, fn key ->
      Map.get(socket.assigns, key) != assign_value(key, Map.fetch!(active, key))
    end)
  end

  # A mode flip moves level, karma and faction as well, but every page that
  # cares re-derives its whole view from the `:mode` ping alone - so announcing
  # the others too would only buy duplicate reflows (on Tasks, a duplicate
  # requery of the entire quest graph). Collapse to the one message.
  defp announce(socket, changed) do
    keys = if :mode in changed, do: [:mode], else: changed

    Enum.each(keys, fn key ->
      send(self(), {:sidebar_state_changed, key, Map.get(socket.assigns, key)})
    end)
  end

  # ── Cross-tab broadcasts ───────────────────────────────────────────

  # Our own echo: already applied synchronously in `put_pref/3`.
  defp handle_info({:operator_session, from_pid, _payload}, socket) when from_pid == self() do
    {:halt, socket}
  end

  defp handle_info({:operator_session, _from, {:prefs_changed, prefs}}, socket) do
    {:halt, apply_prefs(socket, prefs, false)}
  end

  # Another tab changed the progress blob. Pages already know how to rehydrate
  # from a restored blob, so reuse that contract.
  defp handle_info({:operator_session, _from, {:progress_changed, progress}}, socket) do
    send(self(), {:client_state_restored, progress})
    {:halt, assign(socket, :client_state, progress)}
  end

  # A reset/import in another tab. That tab reloads itself; this one re-syncs to
  # the fresh defaults so the two don't disagree.
  #
  # Only keys that ACTUALLY changed are announced. Announcing all of them would
  # cost several full reflows per tab - on Tasks a `:mode` ping alone re-queries
  # the whole task graph - for values that may not have moved at all.
  defp handle_info({:operator_session, _from, {:reset, snapshot}}, socket) do
    # `apply_prefs/3` already announces only what moved; `persist?: false`
    # because the tab that reset has rewritten the cookie itself.
    socket = apply_prefs(socket, snapshot.prefs, false)

    if socket.assigns.client_state != snapshot.progress do
      send(self(), {:client_state_restored, snapshot.progress})
    end

    # DELIBERATELY NO `eft:clear` PUSH HERE. An earlier revision of this pass added
    # one, reasoning that since `eft:store` now merges per mode, a reset must say
    # "remove keys" explicitly. That was wrong, and it silently broke **backup
    # import**.
    #
    # Both client actions that reach this broadcast put `localStorage` into the state
    # they want BEFORE navigating through `EftBuddyWeb.SessionController`:
    # "Reset progress" calls `clearAll()` (so storage is already empty), and "Import
    # backup" calls `applyBackup()` (so storage already holds the imported blob).
    # The reset route then rotates the token and redirects. The server sees one
    # indistinguishable `{:reset, _}` in both cases — so pushing `eft:clear` on it
    # deleted the file the operator had just restored, and the redirect then
    # cold-seeded from empty storage. Import appeared to do nothing except erase
    # whatever the device already had.
    #
    # The client is the party that knows the intent and has already acted on it, so
    # the server has nothing to add. Other tabs converge correctly without it: their
    # `:client_state` becomes `snapshot.progress`, and because the browser-side
    # `eft:store` handler merges, their next write cannot destroy whatever storage
    # now holds — they pick the new contents up on their next `eft:restore`.
    #
    # `:progress_seeded?` becomes TRUE: `localStorage` is in a state the client just
    # chose, so later writes may push again. Leaving it false would make every
    # subsequent click in this tab fail to persist.
    socket =
      socket
      |> assign(:client_state, snapshot.progress)
      |> assign(:progress_seeded?, true)

    {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # ── Presentation helpers (used by the layout) ──────────────────────

  @doc """
  Map a PMC level (1..79) to the Tarkov rank emblem filename. The wiki ships
  emblems at levels 1, 5, 10, ..., 75; in-between levels reuse the highest
  emblem at or below the current level. Files live at
  `priv/static/images/ranks/RankN.webp`.
  """
  @spec rank_image_path(integer()) :: String.t()
  def rank_image_path(level) when is_integer(level),
    do: "/images/ranks/Rank#{rank_tier(level)}.webp"

  @doc "The rank-tier number (the N in RankN.webp) for a level."
  @spec rank_tier(integer()) :: integer()
  def rank_tier(level) when level < 5, do: 1
  def rank_tier(level) when level >= 75, do: 75
  def rank_tier(level), do: div(level, 5) * 5

  @doc "Minimum allowed PMC level."
  defdelegate min_level(), to: Operator
  @doc "Maximum allowed PMC level (in-game cap)."
  defdelegate max_level(), to: Operator
  @doc "Minimum scav-karma value."
  defdelegate min_karma(), to: Operator
  @doc "Maximum scav-karma value."
  defdelegate max_karma(), to: Operator
end
