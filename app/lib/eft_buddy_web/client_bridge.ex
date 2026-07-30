defmodule EftBuddyWeb.ClientBridge do
  @moduledoc """
  The *transport* between the browser's durable storage and the server-side
  operator session. Deliberately separate from `EftBuddyWeb.OperatorState`,
  which owns what the values mean: this module only moves them.

  Since EFT-Buddy has no accounts, the browser holds the durable record:

    * `localStorage` (`eft_buddy_state_v2`) - the progress blob: watchlists,
      favourites, completed tasks, hideout. Namespaced per game mode; see
      `EftBuddy.Progress`.
    * the `eft_prefs` cookie - the small operator prefs, also per game mode
      (handled on the request side by `EftBuddyWeb.Plugs.OperatorSession`).

  `EftBuddy.OperatorSession` is authoritative while the connection lives, so the
  client only speaks up at the one moment it genuinely knows better:

    * `"eft:restore"` - **cold boot.** The `Hud` hook hands up the `localStorage`
      blob on connect. The server can never read `localStorage` itself, so this
      is the only way progress enters a fresh session. Seeding is once-only: a
      later push (a second tab connecting) can't clobber work already done.

  Server -> client pushes keep the durable copy current:

    * `"eft:cookie"` - the operator's prefs (issued by `OperatorState`). A
      complete snapshot that **replaces** the cookie: the server re-derives the
      whole pref set on every write, and prefs are cheap to re-enter.
    * `"eft:store"` - the operator's progress blob (issued via `put_progress/2`).
      A complete snapshot that the browser **merges per game mode**.

  ## Why progress merges and prefs replace

  `localStorage` is the *only* durable copy of progress. This session lives in a
  process that can die - a 4h idle shutdown, a crash (`restart: :temporary`), a
  deploy - and be resurrected empty by the very next write. While `"eft:store"`
  replaced the browser's copy, that single write destroyed everything the
  operator had tracked, with no server-side artefact to reconstruct from.

  So the contract is: **the server is authoritative about the keys it sends, and
  says nothing about the keys it omits.** The browser is the only party that can
  see both copies, so it is the browser that merges (see `mergeProgress` in
  `app.js`). Shrinking is never implicit - `"eft:clear"` is the one channel
  allowed to remove keys, and `OperatorState` pushes it on a reset.

  Merging per *mode* rather than per blob is what makes this safe: a slice's
  values are whole lists the server replaces deliberately (unwatchlisting sends
  the shorter list, it does not drop the key), so only absence is ignored.

  Pages must write progress through `put_progress/2` rather than pushing
  `"eft:store"` directly, so the authority and the browser never disagree.

  ## Both writes here carry seed state, not just their payload

  A write can find the session gone and restart it (see `EftBuddy.OperatorSessions`),
  so every write hands back enough state for the resurrected session to come back as
  the operator left it - `:seed_progress` for the blob, `:seed_prefs` for the HUD.

  This module is otherwise pure transport and owns none of these values; it carries
  them because it is the party holding a socket at the moment the session dies. A
  write that omits either seed does not fail - it quietly rebuilds the session from
  defaults, which is indistinguishable from success until the next mount.

  Note that *discarding* server state (the "Reset progress" / "Import backup"
  actions) deliberately does **not** go through this socket bridge - it is a
  plain navigation to `EftBuddyWeb.SessionController`, because it must work
  while the socket is down. See that module for the reasoning.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias EftBuddy.Operator
  alias EftBuddy.OperatorSessions
  alias EftBuddy.Progress

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :client_bridge_events, :handle_event, &handle_event/3)}
  end

  @doc """
  Persist a progress patch: merge it into the authoritative session **and**
  push it to the browser's `localStorage`.

  The patch is written into the slice for the socket's **active game mode**, so
  a caller just hands over its own flat keys (`%{"tasks_watchlist" => [...]}`)
  and never has to know progress is namespaced. See `EftBuddy.Progress`.

  What gets pushed to the browser is the resulting **whole blob**, not the
  patch, and the browser merges it per game mode - see the moduledoc.

  The returned socket carries an updated `:client_state`, so a caller that
  re-derives from the blob (e.g. the Tasks page on a mode flip) sees its own
  write immediately without waiting for a client round-trip.
  """
  def put_progress(socket, patch) when is_map(patch) do
    mode = socket.assigns.mode

    # What this socket knows, with the patch applied. This is a FLOOR: whatever
    # the session answers, the blob we hand back can never carry fewer keys than
    # this. Three things can make the session answer with less: a 4h idle
    # shutdown, a crash (`restart: :temporary`), and a `reset` in another tab,
    # which empties this socket's session while it still holds the pre-rotation
    # token.
    local = Progress.merge(socket.assigns.client_state, mode, patch)

    progress =
      case OperatorSessions.merge_progress(socket.assigns.operator_token, mode, patch,
             seed_progress: socket.assigns.client_state,
             seed_prefs: seed_prefs(socket)
           ) do
        # The session stays authoritative key-by-key (`adopt/2` lets its second
        # argument win), but keys only this socket knows about are carried up
        # rather than dropped.
        {:ok, progress} ->
          Progress.adopt(local, progress)

        # No session reachable at all. The socket's cache MUST still advance -
        # otherwise a page that re-derives from `:client_state` (e.g. Tasks on a
        # mode flip) would roll back the write the operator just made.
        :unchanged ->
          local
      end

    socket = assign(socket, :client_state, progress)

    # Do not rewrite the durable copy until the browser has told THIS socket what
    # it holds.
    #
    # `:progress_seeded?` is false in exactly one situation that matters: this
    # mount *created* the session rather than finding one. That is either a
    # genuine first visit - `localStorage` is empty, so there is nothing to lose -
    # or a socket REJOIN whose session had died. On a rejoin the `Hud` hook's
    # `mounted()` does not re-run, so `:client_state` is empty while
    # `localStorage` may hold a full history, and every list the page derives is
    # computed from nothing. The per-mode merge in `app.js` protects the keys we
    # OMIT; it cannot protect a key we send with a wrongly-short list.
    #
    # The hook's `reconnected()` closes that window immediately, so the cost is at
    # most one dropped push. The write itself still lands - in the session and on
    # screen - it is only the durable copy we decline to touch while blind.
    if socket.assigns.progress_seeded? do
      push_event(socket, "eft:store", progress)
    else
      socket
    end
  end

  # The browser handing up its `localStorage`: on a cold connect, and again on
  # every socket rejoin (see the `Hud` hook's `reconnected()`).
  defp handle_event("eft:restore", payload, socket) when is_map(payload) do
    incoming = Progress.normalize(payload)

    # The browser has now spoken to this socket, so from here on `:client_state`
    # is a floor we can trust and `put_progress/2` may push again.
    socket = assign(socket, :progress_seeded?, true)

    socket =
      case OperatorSessions.seed_progress(socket.assigns.operator_token, incoming,
             seed_prefs: seed_prefs(socket)
           ) do
        {:ok, progress} ->
          # Pages rehydrate from this message.
          send(self(), {:client_state_restored, progress})
          assign(socket, :client_state, progress)

        # Either the session had nothing to learn, or it is already seeded, or
        # there is no session at all. Either way this socket must still end up
        # holding at least what the browser just handed up, or its floor would sit
        # below the durable copy. `adopt/2` lets its second argument win, so the
        # session's values stay authoritative and the browser's extras are taken
        # up.
        :unchanged ->
          assign(
            socket,
            :client_state,
            Progress.adopt(incoming, socket.assigns.client_state)
          )
      end

    {:halt, socket}
  end

  # Any other `eft:*` event is a client running PRE-deploy JavaScript, pushing
  # something this version no longer knows about (`eft:prefs` was removed when
  # prefs became server-authoritative; `eft:reset` when reset became a plain
  # navigation).
  #
  # Swallow it. Without this the unknown event falls through to the page, whose
  # `handle_event/3` has no matching clause, and the LiveView crashes - and
  # because the stale tab reconnects with the *same* stale JS, it crash-loops
  # until the visitor happens to hard-reload. A tab open across a deploy must
  # degrade to "the server ignores my obsolete push", never to a broken page.
  #
  # Keep this clause even as the event set changes: it is what makes removing a
  # client event a safe, backwards-compatible operation.
  defp handle_event("eft:" <> _legacy_event, _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # Both writes above can RESURRECT a dead session, and a session built with no
  # `:seed_prefs` is built from `Operator.parse_all(%{})` - a complete set of
  # defaults, `:mode` included. See `EftBuddy.OperatorSessions`, whose moduledoc
  # states the obligation this satisfies.
  #
  # Nothing is visible when that goes wrong. This socket's assigns are untouched,
  # so the tab keeps rendering the operator's real prefs; the loss lands on the
  # NEXT mount, which finds the session alive, takes its defaults as authoritative
  # and pushes them over the `eft_prefs` cookie. A reverted `:mode` is the worst of
  # them, because progress is namespaced per mode - the operator's board comes back
  # empty and their next writes accumulate in the slice they are not looking at.
  #
  # `Operator.cookie_payload/1` rather than the internal pref map: karma is integer
  # hundredths internally but karma units on the way in, so handing the internal
  # value to `parse_all/1` would multiply it by 100.
  #
  # `OperatorState` computes the same thing for its own writes (`visible_prefs/1`).
  # Not shared: it is one call to a public function, and the subtlety that makes it
  # worth commenting lives inside `cookie_payload/1`, which both sides go through.
  defp seed_prefs(socket), do: Operator.cookie_payload(socket.assigns.operator_prefs)
end
