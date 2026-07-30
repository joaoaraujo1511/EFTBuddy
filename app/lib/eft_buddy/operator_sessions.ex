defmodule EftBuddy.OperatorSessions do
  @moduledoc """
  The public API in front of `EftBuddy.OperatorSession` processes.

  Callers never touch a pid or a `Registry` tuple - they pass the operator's
  token and this module resolves it, starting the session on demand.

  ## Fault tolerance

  Every call is wrapped so a session that is missing, mid-restart, or has just
  timed out can never crash a LiveView mount. Reads fall back to the browser's
  own (cookie-seeded) values; **writes transparently restart the session** so a
  HUD control can never become silently inert after an idle shutdown. Callers
  pass `:seed_prefs` on a write so a resurrected session comes back with the
  state the operator can currently see, rather than bare defaults.

  Losing this state is always recoverable, because the browser still holds the
  durable copy - so degrading quietly is the correct trade here.

  ## Session creation is gated on a live socket

  `snapshot/3` only *creates* a session when told to (`create: true`), which
  `EftBuddyWeb.OperatorState` does exclusively on the connected mount. A
  disconnected (static) render can read the `eft_prefs` cookie directly, so it
  needs no process - and a crawler or health-check GET therefore allocates
  nothing. `@max_children` is a further backstop: past that ceiling, callers
  degrade to cookie-only values instead of exhausting the node.

  ## Multi-node

  Sessions are node-local: the `Registry` is not distributed. Behind a load
  balancer without sticky sessions an operator could land on a node with no
  session for their token, which simply re-seeds from their cookie /
  `localStorage` - correct, just one extra hydration. Running more than one
  node with a shared cookie domain therefore wants either sticky sessions or a
  distributed registry.
  """

  alias EftBuddy.Operator
  alias EftBuddy.OperatorSession
  alias EftBuddy.Progress

  @registry EftBuddy.OperatorSessions.Registry
  @supervisor EftBuddy.OperatorSessions.Supervisor

  # A call should never make a mount wait on a wedged process.
  @call_timeout 2_000

  @doc "The PubSub topic carrying one operator's state changes."
  @spec topic(String.t()) :: String.t()
  def topic(token) when is_binary(token), do: "operator_session:" <> token

  @doc """
  Subscribe the calling process to an operator's change broadcasts.

  Used by the `on_mount` hook so every open tab converges on the same state.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(token) when is_binary(token) do
    Phoenix.PubSub.subscribe(EftBuddy.PubSub, topic(token))
  end

  @doc false
  def broadcast(token, payload, from_pid) when is_binary(token) do
    Phoenix.PubSub.broadcast(
      EftBuddy.PubSub,
      topic(token),
      {:operator_session, from_pid, payload}
    )
  end

  @doc """
  The operator's current state.

  ## Options

    * `:seed_prefs` - the `eft_prefs` cookie payload bridged into the session by
      `EftBuddyWeb.Plugs.OperatorSession`. Used **only** to cold-seed a session
      that does not exist yet: a live session is authoritative and must never be
      overwritten by a mount's frozen connect-time snapshot.
    * `:create` - whether to start a session when none exists (default `false`).
      Pass `true` only from a connected mount; see the moduledoc.
  """
  @spec snapshot(String.t() | nil, keyword()) :: %{
          prefs: Operator.prefs(),
          progress: map(),
          progress_seeded?: boolean()
        }
  def snapshot(token, opts \\ [])

  def snapshot(nil, opts), do: fallback_snapshot(opts)

  def snapshot(token, opts) when is_binary(token) do
    cond do
      alive?(token) ->
        call(token, :snapshot, fallback_snapshot(opts))

      Keyword.get(opts, :create, false) ->
        case ensure_started(token, opts) do
          {:ok, _pid} -> call(token, :snapshot, fallback_snapshot(opts))
          :error -> fallback_snapshot(opts)
        end

      true ->
        # No session and we're not allowed to make one (static render): the
        # cookie is a perfectly good source here, since this *is* an HTTP
        # request that could read it.
        fallback_snapshot(opts)
    end
  end

  @doc """
  Set one operator pref.

  Returns `{:ok, prefs}` - the *whole* resulting pref set - when the value
  actually changed, or `:unchanged` when it was already current / invalid. The
  full set comes back because a change to `:mode` swaps the active slice, and
  therefore level, karma and faction along with it.

  ## Options

    * `:from` - the pid stamped on the broadcast, so the originating LiveView
      can skip its own echo (default `self()`).
    * `:seed_prefs` - state to restore the session with if it is no longer
      running, so a write after an idle shutdown doesn't silently reset the
      operator's other prefs to defaults.
  """
  @spec put_pref(String.t() | nil, Operator.pref_key(), term(), keyword()) ::
          {:ok, Operator.prefs()} | :unchanged
  def put_pref(token, key, value, opts \\ [])

  def put_pref(nil, key, value, opts) do
    # No session (e.g. a static render). Still validate and fold the change into
    # the prefs the caller can currently see, so it renders optimistically; it
    # just won't outlive this render.
    case Operator.parse(key, value) do
      nil ->
        :unchanged

      parsed ->
        prefs = opts |> Keyword.get(:seed_prefs, %{}) |> Operator.parse_all()
        {:ok, Operator.put_pref(prefs, key, parsed)}
    end
  end

  def put_pref(token, key, value, opts) when is_binary(token) do
    write(token, {:put_pref, key, value, from(opts)}, opts)
  end

  @doc """
  Merge a patch into one game mode's slice of the operator's progress blob.

  See `put_pref/4` for options. `mode` is the *active* game mode, since progress
  is namespaced per mode (`EftBuddy.Progress`) - a write must never touch the
  mode the operator isn't currently in.
  """
  @spec merge_progress(String.t() | nil, Progress.mode(), map(), keyword()) ::
          {:ok, map()} | :unchanged
  def merge_progress(token, mode, patch, opts \\ [])
  def merge_progress(nil, _mode, _patch, _opts), do: :unchanged

  def merge_progress(token, mode, patch, opts) when is_binary(token) and is_map(patch) do
    write(token, {:merge_progress, mode, patch, from(opts)}, opts)
  end

  @doc """
  Seed the operator's progress from the browser's `localStorage`, which happens
  once per session on the first connect. Ignored if already seeded.
  """
  @spec seed_progress(String.t() | nil, map(), keyword()) :: {:ok, map()} | :unchanged
  def seed_progress(token, progress, opts \\ [])
  def seed_progress(nil, _progress, _opts), do: :unchanged

  def seed_progress(token, progress, opts) when is_binary(token) and is_map(progress) do
    write(token, {:seed_progress, progress, from(opts)}, opts)
  end

  @doc """
  Return an operator's session to factory state.

  Called when the browser resets or imports a backup. The reloading tab gets a
  freshly rotated token (see `EftBuddyWeb.SessionController`), so this exists to
  converge the operator's *other* open tabs, which are still attached to this
  session.

  Deliberately does not create a session: if there is none, there is nothing to
  reset.
  """
  @spec reset(String.t() | nil, keyword()) :: {:ok, map()} | :unchanged
  def reset(token, opts \\ [])
  def reset(nil, _opts), do: :unchanged

  def reset(token, opts) when is_binary(token) do
    if alive?(token), do: call(token, {:reset, from(opts)}, :unchanged), else: :unchanged
  end

  @doc "Whether a session process currently exists for this token."
  @spec alive?(String.t()) :: boolean()
  def alive?(token) when is_binary(token), do: Registry.lookup(@registry, token) != []
  def alive?(_token), do: false

  @doc """
  The maximum number of concurrent operator sessions.

  ONE definition, read by two places that must agree: the `DynamicSupervisor`'s
  `max_children` in `EftBuddy.Application`, which enforces it, and `stats/0`,
  which reports headroom against it. They used to hold their own copies of the
  literal — a gauge measuring against a number the supervisor does not enforce
  is worse than no gauge.

  ## Where 5,000 comes from

  This was 50,000, under a comment reading *"Each session holds a few KB."*
  `EftBuddy.Progress` admits **128 KB per mode slice × 2 modes**
  (`progress.ex:78, 43`), retained for four hours after disconnect
  (`operator_session.ex:70`) — so the admissible worst case was ~13 GB on a node
  chosen for a free-first hosting budget. The unit was wrong: the limit counts
  processes, the resource is bytes.

      5,000 ×  40 KB (realistic heavy session) =  200 MB
      5,000 × 256 KB (theoretical worst case)  = 1.25 GB

  Erring low is safe and erring high is not. Past the ceiling callers degrade to
  cookie-only state via `fallback_snapshot/1` — the site keeps serving and the
  browser keeps its own durable copy; it just stops tracking new visitors
  server-side. Exceeding memory takes the node down for everyone.

  Override with `MAX_OPERATOR_SESSIONS` once the instance size is known; see
  `config/runtime.exs`.
  """
  @spec ceiling() :: pos_integer()
  def ceiling, do: Application.get_env(:eft_buddy, :max_operator_sessions, 5_000)

  @doc """
  How many operator sessions are currently alive, and the ceiling they are
  counted against.

  This is the only visibility into the `max_children` backstop. Past the ceiling
  every caller silently degrades to cookie-only state (`fallback_snapshot/1`),
  which is correct behaviour but completely invisible — the site keeps answering
  200 while progress stops being tracked for new visitors. Approaching the ceiling
  is therefore something an operator wants to know *before* it happens.
  """
  @spec stats() :: %{count: non_neg_integer(), ceiling: pos_integer()}
  def stats do
    count =
      case DynamicSupervisor.count_children(@supervisor) do
        %{active: active} -> active
        _ -> 0
      end

    %{count: count, ceiling: ceiling()}
  catch
    # The supervisor isn't running (narrow test setups) — report zero rather than
    # letting a measurement crash the poller.
    :exit, _reason -> %{count: 0, ceiling: 0}
  end

  @doc false
  # Invoked by `:telemetry_poller` (see `EftBuddyWeb.Telemetry`).
  def emit_telemetry do
    %{count: count, ceiling: ceiling} = stats()
    :telemetry.execute([:eft_buddy, :operator_sessions], %{count: count, ceiling: ceiling}, %{})
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp from(opts), do: Keyword.get(opts, :from, self())

  # Writes must not be lost to an idle shutdown, so they start the session if
  # it's gone. `:seed_prefs` and `:seed_progress` let the caller hand back the
  # state the operator can currently see, so a resurrected session doesn't
  # silently drop whatever isn't part of this particular write.
  #
  # `:seed_progress` is the load-bearing half for DATA LOSS, not just for UI
  # staleness: the browser's `localStorage` is the only durable copy of progress,
  # and `ClientBridge.put_progress/2` pushes the session's answer back over it as
  # a full replacement. A session that came back empty would therefore erase the
  # operator's entire history. See `EftBuddyWeb.ClientBridge.put_progress/2`.
  defp write(token, message, opts) do
    case ensure_started(token, opts) do
      {:ok, _pid} -> call(token, message, :unchanged)
      :error -> :unchanged
    end
  end

  # Takes the caller's whole `opts` rather than one seed, so a new kind of seed
  # is a change here and in `OperatorSession.init/1` only.
  defp ensure_started(token, opts) do
    spec =
      {OperatorSession,
       token: token,
       seed_prefs: Keyword.get(opts, :seed_prefs, %{}),
       seed_progress: Keyword.get(opts, :seed_progress, %{})}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      # Another mount for the same operator won the race (or the session was
      # already live) - reuse it. Never re-seed in this branch.
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> :error
    end
  catch
    # The supervisor isn't running (possible in narrow test setups). Callers
    # degrade to the browser's own values rather than failing the mount.
    :exit, _reason -> :error
  end

  # A session can die between resolution and the call (idle timeout is a race
  # by nature), so treat any exit as "no session" and hand back the fallback.
  defp call(token, message, fallback) do
    GenServer.call(OperatorSession.via(token), message, @call_timeout)
  catch
    :exit, _reason -> fallback
  end

  defp fallback_snapshot(opts) do
    seed_prefs = Keyword.get(opts, :seed_prefs, %{})

    %{
      prefs: Operator.parse_all(seed_prefs),
      progress: Progress.empty(),
      progress_seeded?: false
    }
  end
end
