defmodule EftBuddy.OperatorSession do
  @moduledoc """
  The authoritative store for one operator's *live* state, for the lifetime of
  their connection to the app.

  ## Why this process exists

  EFT-Buddy has no accounts: operator prefs (PMC level, mode, faction, karma)
  and progress (watchlists, completed tasks) are durably owned by the browser -
  a JS-writable `eft_prefs` cookie and a `localStorage` blob.

  Both stores are namespaced per game mode, because PVP and PVE are separate
  progressions: `EftBuddy.Operator` owns that layout for prefs and
  `EftBuddy.Progress` for progress. This process just holds whatever they say
  the canonical shape is.

  That works on a full HTTP request, where a plug can read the cookie. It does
  *not* work for LiveView navigation. `<.link navigate>` dismounts one LiveView
  and mounts the next over the same socket, and `on_mount` then runs against
  the socket's **connect-time** session - a snapshot frozen when the WebSocket
  first connected, which no later cookie write can update. `localStorage` is
  worse: the server can never read it at all.

  The historical workaround was to let the first render be wrong and correct it
  from a client round-trip (`eft:prefs` / `eft:restore`). That is what made the
  HUD visibly snap from defaults to real values on every navigation, and made
  watchlists render empty before popping in.

  This process inverts the ownership so the first render is simply correct:

    * **The server is authoritative while the connection lives.** Every mount,
      including a live navigation, reads current values from here.
    * **The browser is the durable cold-boot backup.** Values are still written
      through to the cookie / `localStorage`, and a session that doesn't exist
      yet is seeded from them.

  Nothing here is persisted. On a deploy or restart the process is gone and the
  next connect re-seeds from the browser - which is why client storage remains
  the real record of truth.

  ## Lifetime

  One process per `operator_token` (a signed, per-browser token minted by
  `EftBuddyWeb.Plugs.OperatorSession`), registered in
  `EftBuddy.OperatorSessions.Registry` and supervised by
  `EftBuddy.OperatorSessions.Supervisor`.

  The process is *not* linked to any socket: a reload or a brief network drop
  would otherwise discard state we want to keep. Instead it shuts itself down
  after `idle_timeout` with no activity, which also bounds memory for
  one-off visitors.

  ## Change notification

  Every mutation broadcasts on `EftBuddy.OperatorSessions.topic/1` so *all* of
  an operator's open tabs converge. The mutating pid is carried in the message
  so the originator can ignore its own echo (it has already applied the
  change locally).
  """

  use GenServer, restart: :temporary

  alias EftBuddy.Operator
  alias EftBuddy.Progress

  # No activity for this long and the session shuts down. Long enough to cover
  # a normal browsing session (and a laptop lid closing), short enough that
  # drive-by visitors on a public, account-free site don't accumulate. Tunable
  # via `config :eft_buddy, :operator_session_idle_timeout` (milliseconds).
  @default_idle_timeout :timer.hours(4)

  defstruct token: nil,
            prefs: %{},
            progress: %{},
            # Whether the BROWSER has handed up its `localStorage` for this
            # session yet. Strictly about the client having spoken - not about
            # whether we've written anything (see `:merge_progress`) - so that
            # one cold-boot hydration happens exactly once.
            progress_seeded?: false,
            idle_timeout: nil

  @type t :: %__MODULE__{}

  @doc false
  def start_link(opts) do
    token = Keyword.fetch!(opts, :token)
    GenServer.start_link(__MODULE__, opts, name: via(token))
  end

  @doc false
  def via(token), do: {:via, Registry, {EftBuddy.OperatorSessions.Registry, token}}

  @doc """
  How long a session may sit idle before shutting itself down, in milliseconds.

  Falls back to a 4 hour default; override with
  `config :eft_buddy, :operator_session_idle_timeout, :timer.hours(1)`.
  """
  def default_idle_timeout do
    Application.get_env(:eft_buddy, :operator_session_idle_timeout, @default_idle_timeout)
  end

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # `seed_prefs` comes from the `eft_prefs` cookie on the request that
    # created this session, and is only ever applied here - once, at birth.
    # Later mounts must never re-seed from their own (possibly staler)
    # connect-time cookie snapshot; that is precisely the bug this fixes.
    # `parse_all/1` already returns a COMPLETE pref set (defaults filled in for
    # anything the cookie didn't carry or got wrong), so there is nothing to
    # merge over `defaults/0` here. Merging would in fact be wrong now that
    # prefs are nested: a shallow merge replaces the whole `:modes` map.
    # `seed_progress` is the equivalent for the progress blob, and exists for a
    # sharper reason than prefs do. A write that RESURRECTS a session (idle
    # timeout, crash, or a `reset` in another tab) has its result pushed straight
    # back to the browser, where it REPLACES `localStorage` — the only durable
    # copy of the operator's progress. Coming back as `Progress.empty()` there
    # silently destroyed everything they had tracked. The writer therefore hands
    # over what it still knows; see `EftBuddyWeb.ClientBridge.put_progress/2`.
    #
    # `progress_seeded?` is deliberately left `false`: this is the SERVER's guess
    # restored from a socket, not the browser having spoken, so the one-shot
    # cold-boot hydration must still be allowed to happen and win.
    state = %__MODULE__{
      token: Keyword.fetch!(opts, :token),
      prefs: opts |> Keyword.get(:seed_prefs, %{}) |> Operator.parse_all(),
      progress: opts |> Keyword.get(:seed_progress, %{}) |> Progress.normalize(),
      idle_timeout: Keyword.get(opts, :idle_timeout, default_idle_timeout())
    }

    {:ok, state, state.idle_timeout}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    reply(snapshot(state), state)
  end

  # Assign a pref. Per-mode keys land in the active mode's slice; `Operator`
  # owns that routing. Returns the whole resulting pref set rather than just the
  # one value, because changing `:mode` implicitly changes level / karma /
  # faction too - the caller has to re-derive all of them, not patch one.
  # `:unchanged` (value already current, or invalid) suppresses both the
  # broadcast and the caller's reflow.
  def handle_call({:put_pref, key, value, from_pid}, _from, state) do
    with true <- Operator.pref_key?(key),
         parsed when not is_nil(parsed) <- Operator.parse(key, value),
         false <- Operator.get_pref(state.prefs, key) == parsed do
      prefs = Operator.put_pref(state.prefs, key, parsed)
      state = %{state | prefs: prefs}
      broadcast(state, {:prefs_changed, prefs}, from_pid)
      reply({:ok, prefs}, state)
    else
      _ -> reply(:unchanged, state)
    end
  end

  # Merge a patch into ONE GAME MODE's progress slice. Merging (rather than
  # replacing) keeps each page owning only its own keys, and doing it in this
  # single process serialises the read-modify-write that the old client-side
  # `{...readProgress(), ...patch}` could lose between tabs.
  #
  # Deliberately does NOT set `progress_seeded?`: that flag tracks whether the
  # *browser* has handed up its storage, which is a separate question from
  # whether we've written anything. Conflating the two would make a write that
  # beat the client's push suppress the seed entirely, discarding every key the
  # server hadn't happened to touch.
  def handle_call({:merge_progress, mode, patch, from_pid}, _from, state) when is_map(patch) do
    progress = Progress.merge(state.progress, mode, patch)

    if progress == state.progress do
      reply(:unchanged, state)
    else
      state = %{state | progress: progress}
      broadcast(state, {:progress_changed, progress}, from_pid)
      reply({:ok, progress}, state)
    end
  end

  # The browser handing up its `localStorage` blob on a cold connect - the one
  # moment the client knows something the server doesn't.
  #
  # Merged with **server keys winning**, not replaced. Keys we already hold are
  # newer by definition (they were written during this session), so they must
  # survive; but keys only the browser knows about have to be adopted rather
  # than dropped. A plain "replace unless already seeded" would silently discard
  # the operator's entire stored progress if any write happened to land before
  # this push (e.g. a very fast click on a freshly mounted page), and that write
  # would then overwrite their localStorage - real data loss from a narrow race.
  def handle_call({:seed_progress, progress, from_pid}, _from, state) when is_map(progress) do
    merged = Progress.adopt(progress, state.progress)

    cond do
      state.progress_seeded? ->
        reply(:unchanged, state)

      # Nothing new (e.g. a first-time visitor handing up an empty blob). Record
      # that the browser has spoken, but don't broadcast: telling every page to
      # rehydrate would cost a full reflow - and a task requery - for no change.
      merged == state.progress ->
        reply(:unchanged, %{state | progress_seeded?: true})

      true ->
        state = %{state | progress: merged, progress_seeded?: true}
        broadcast(state, {:progress_changed, merged}, from_pid)
        reply({:ok, merged}, state)
    end
  end

  # Back to factory settings, for the "Reset progress" / "Import backup"
  # actions. Without this the server would keep serving the pre-reset values
  # (it is authoritative now) and the reset would look like it did nothing.
  def handle_call({:reset, from_pid}, _from, state) do
    state = %{
      state
      | prefs: Operator.defaults(),
        progress: Progress.empty(),
        progress_seeded?: false
    }

    broadcast(state, {:reset, snapshot(state)}, from_pid)
    reply({:ok, snapshot(state)}, state)
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp reply(response, state), do: {:reply, response, state, state.idle_timeout}

  defp snapshot(state) do
    %{
      prefs: state.prefs,
      progress: state.progress,
      progress_seeded?: state.progress_seeded?
    }
  end

  defp broadcast(state, payload, from_pid) do
    EftBuddy.OperatorSessions.broadcast(state.token, payload, from_pid)
  end
end
