defmodule EftBuddy.Progress do
  @moduledoc """
  The shape of an operator's *progress* blob, and the only place that knows it.

  Escape from Tarkov's PVP and PVE modes are separate progressions: separate
  level, separate karma, separate quest completions, separate hideout. The
  tracker mirrors that, so every piece of progress the operator can change is
  stored **per game mode**:

      %{
        "modes" => %{
          "pvp" => %{"completed_tasks" => [...], "tasks_watchlist" => [...], ...},
          "pve" => %{"completed_tasks" => [...], "tasks_watchlist" => [...], ...}
        }
      }

  Pages never index into that structure themselves - they go through `get/4`
  and hand patches to `EftBuddyWeb.ClientBridge.put_progress/2`, which routes
  the write into the active mode's slice. Keeping the layout here is what makes
  "is this value per-mode?" a single decision rather than one repeated (and
  previously forgotten) in five LiveViews.

  ## Everything here is defensive

  The blob's durable home is the browser's `localStorage`, which is
  user-writable, survives across deploys, and can be hand-edited or corrupted.
  `normalize/1` therefore coerces *any* input into the canonical shape, and
  every read falls back to an empty slice. A malformed blob can degrade to "no
  progress recorded"; it can never raise.

  Note that normalizing **drops unrecognised keys**, including the flat,
  pre-per-mode layout. That is deliberate: the `localStorage` key is versioned
  (`eft_buddy_state_v2`), so an older blob is never read in the first place, and
  silently half-reading one would be worse than starting clean.

  Progress keys are strings throughout, because the blob round-trips through
  JSON to the browser. Game modes are accepted as either atoms (`:pvp`, as the
  LiveView assign carries it) or strings.
  """

  # Mirrors `EftBuddy.Operator.game_modes/0`, as strings, since this blob is
  # JSON. Kept as its own list so this module stays free of pref concerns.
  @modes ~w(pvp pve)

  # Every key a mode slice may carry. `normalize/1` drops anything else.
  #
  # This is a security boundary, not tidiness. The blob arrives from an
  # unauthenticated browser over `eft:restore`, is held in an `OperatorSession`
  # for up to four hours after the socket closes, and the DynamicSupervisor
  # ceiling allows 50,000 such sessions - so an unbounded map here is a remote
  # memory-exhaustion path. Keep this list in step with the `@..._key` module
  # attributes in the LiveViews that write progress; a key missing from here is
  # silently discarded, which a new feature would notice immediately in dev.
  @slice_keys ~w(
    completed_tasks
    tasks_watchlist
    items_watchlist
    events_watchlist
    hideout_checks
    hideout
    flea_favorites
  )

  # Ceiling on one mode slice, measured with `:erlang.external_size/1` (cheap,
  # allocates no binary). A real operator's slice is a few tens of KB at most -
  # ~1000 quest slugs plus watchlists - so this is generous by an order of
  # magnitude while still bounding the process.
  #
  # Two slices at this ceiling is the WHOLE retention bound per session, which is
  # what `max_frame_size` in `EftBuddyWeb.Endpoint` is sized against: the frame cap
  # has to sit comfortably ABOVE 2x this, or a blob the server would happily accept
  # could never arrive - the socket would close 1009, LiveView would reconnect, the
  # `Hud` hook would re-push the identical frame, and the page would be permanently
  # unusable with no diagnostic. The frame cap bounds absurdity; this bounds memory.
  #
  # An over-ceiling slice is REJECTED, never truncated, and the caller keeps
  # whatever it already had - see `bound_slice/3`.
  @max_slice_bytes 128 * 1024

  # ON VALUE VALIDATION, and why it is not done here.
  #
  # The keys are allow-listed and the total is capped, but the CONTENTS of a slice
  # are whatever the client sent: a list of quest slugs is not checked against the
  # tasks table. That is deliberate, and the reasoning belongs next to the cap.
  #
  # Cardinality is what a byte cap bounds badly, so where a key's cardinality is
  # cheap to bound properly, the writing LiveView does it instead of this module -
  # see `EftBuddyWeb.HideoutLive.Index`'s `"toggle_requirement"`, whose composite
  # key is fully client-chosen and whose catalogue is small and entirely present in
  # the socket's assigns.
  #
  # The watchlist keys (`tasks_watchlist`, `items_watchlist`, `events_watchlist`,
  # `flea_favorites`, `completed_tasks`) deliberately do NOT get that treatment.
  # Their catalogues are large and paginated, so a membership check would mean
  # either a database round trip on every star click - on the hottest interaction in
  # the app - or validating against the page currently in assigns, which would
  # silently reject legitimate toggles whenever the visible set had moved on. Both
  # are worse than the residual: junk slugs cost this cap's worth of memory, render
  # as nothing, and are pruned the next time the operator's real progress is
  # written. The `is_binary(slug) and slug != ""` guards on those handlers stop the
  # crash cases; this cap stops the memory case.

  @type mode :: :pvp | :pve | String.t()
  @type t :: %{String.t() => %{String.t() => map()}}

  @doc "Every game mode a progress blob carries a slice for."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "A blob with an empty slice per game mode."
  @spec empty() :: t()
  def empty, do: %{"modes" => Map.new(@modes, &{&1, %{}})}

  @doc """
  Coerce any value into the canonical blob shape.

  Every entry point runs through this: the `localStorage` payload handed up on
  connect, an imported backup, and the session's own state. Unknown top-level
  keys and non-map mode slices are dropped rather than repaired.
  """
  @spec normalize(term()) :: t()
  def normalize(blob) when is_map(blob) do
    slices = blob |> Map.get("modes") |> as_map()

    %{
      "modes" =>
        Map.new(@modes, fn mode ->
          {mode, slices |> Map.get(mode) |> as_map() |> sanitize_slice(%{}, mode)}
        end)
    }
  end

  def normalize(_blob), do: empty()

  @doc "Every key a mode slice may carry; anything else is dropped by `normalize/1`."
  @spec slice_keys() :: [String.t()]
  def slice_keys, do: @slice_keys

  @doc "The per-mode-slice size ceiling in bytes, as `:erlang.external_size/1` measures it."
  @spec max_slice_bytes() :: pos_integer()
  def max_slice_bytes, do: @max_slice_bytes

  # Discard unrecognised keys, then bound what is left. Order matters: taking the
  # allow-list first means a blob padded with thousands of junk keys is cheap to
  # reject and cannot push a legitimate slice over the size ceiling.
  #
  # `fallback` is what the caller keeps if the candidate is over the ceiling. On the
  # read path (`normalize/1`) there is nothing to fall back to, so it is `%{}` - the
  # documented "no progress recorded" state. On the WRITE paths (`merge/3`,
  # `adopt/2`) the pre-write slice is already bounded, so falling back to it rejects
  # the offending write instead of discarding everything the operator had.
  defp sanitize_slice(slice, fallback, mode) do
    slice |> Map.take(@slice_keys) |> bound_slice(fallback, mode)
  end

  defp bound_slice(candidate, fallback, mode) do
    size = :erlang.external_size(candidate)

    if size > @max_slice_bytes do
      # Silent rejection is how a size cap turns into invisible data loss, so make
      # it observable. `EftBuddy.Sync.Reporter` already owns the telemetry handler
      # side; this only has to emit.
      :telemetry.execute(
        [:eft_buddy, :progress, :slice_rejected],
        %{bytes: size, ceiling: @max_slice_bytes},
        %{mode: mode, kept_bytes: :erlang.external_size(fallback)}
      )

      fallback
    else
      candidate
    end
  end

  @doc "One mode's whole slice (`%{}` when absent or malformed)."
  @spec slice(term(), mode()) :: map()
  def slice(blob, mode) do
    blob |> normalize() |> get_in(["modes", mode_key(mode)])
  end

  @doc "One key out of one mode's slice."
  @spec get(term(), mode(), String.t(), term()) :: term()
  def get(blob, mode, key, default \\ nil) when is_binary(key) do
    blob |> slice(mode) |> Map.get(key, default)
  end

  @doc """
  Merge a patch into one mode's slice, leaving every other mode untouched.

  This is the only write path. A shallow merge over the whole blob (what the
  flat layout used to do) would replace the entire `"modes"` map and wipe the
  mode the operator isn't currently in.

  The result is re-sanitised. That is the difference between an input filter and
  an invariant: normalising the base and then merging an arbitrary patch over it
  meant the allow-list and the size ceiling applied only to what was *read*, while
  the value actually stored in the `EftBuddy.OperatorSession` - the thing the
  ceiling exists to bound, held for up to four hours across up to 50,000 sessions
  - was whatever the caller passed. Sanitising the output makes the bound a
  post-condition of every mutation instead.
  """
  @spec merge(term(), mode(), map()) :: t()
  def merge(blob, mode, patch) when is_map(patch) do
    blob = normalize(blob)
    key = mode_key(mode)
    base = blob["modes"][key]

    # `base` is already sanitised, so it is the correct thing to keep if the patch
    # would push the slice over the ceiling: the offending write is rejected, not
    # the operator's history.
    put_in(blob, ["modes", key], sanitize_slice(Map.merge(base, patch), base, key))
  end

  @doc """
  Adopt a client blob under a server one, per mode, with **server keys winning**.

  Used for the one-time cold-boot hydration: keys the session already holds were
  written during this session and are newer by definition, but keys only the
  browser knows about have to be taken up rather than dropped.

  Re-sanitised for the same reason as `merge/3`, and with a sharper edge: both
  inputs can be individually within the ceiling while their union is not, so
  without this the result could be ~2x the cap - and a blob over the cap resolves
  to `%{}` on every subsequent read, i.e. progress present in storage but invisible
  in the UI. The server slice is the fallback, being the newer of the two.
  """
  @spec adopt(term(), term()) :: t()
  def adopt(client, server) do
    client = normalize(client)
    server = normalize(server)

    %{
      "modes" =>
        Map.new(@modes, fn mode ->
          union = Map.merge(client["modes"][mode], server["modes"][mode])
          {mode, bound_slice(union, server["modes"][mode], mode)}
        end)
    }
  end

  @doc "Canonical string form of a game mode; anything unrecognised falls back to PVP."
  @spec mode_key(mode()) :: String.t()
  def mode_key(mode) when is_atom(mode) and not is_nil(mode), do: mode_key(Atom.to_string(mode))
  def mode_key(mode) when is_binary(mode) and mode in @modes, do: mode
  def mode_key(_mode), do: hd(@modes)

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}
end
