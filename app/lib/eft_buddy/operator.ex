defmodule EftBuddy.Operator do
  @moduledoc """
  The operator-preference *domain*: the set of HUD-owned values, their valid
  ranges, and the parsing/clamping rules that guard every entry point.

  This module is deliberately pure - no processes, no sockets, no cookies. It
  is the single place that answers "is this a legal operator pref, and what is
  its canonical form?", and it is shared by:

    * `EftBuddy.OperatorSession` - the per-connection authoritative store
    * `EftBuddyWeb.OperatorState` - the `on_mount` hook + HUD event handlers
    * `EftBuddyWeb.Plugs.OperatorSession` - cold-boot seeding from the cookie

  Because the `eft_prefs` cookie is a plain, JS-writable (hand-editable)
  cookie, **every** value that crosses a boundary is funnelled through
  `parse/2`, which returns `nil` for anything missing or invalid rather than
  guessing. Callers treat `nil` as "leave the current value alone", so a
  truncated or tampered cookie can never do worse than leave a good value in
  place.

  ## Prefs are stored per game mode

  PVP and PVE are separate progressions in Tarkov, so a pref set holds one
  slice per mode (see `t:prefs/0`) and only `:mode` / `:rail_collapsed` are
  global. Pages never see that structure: `active/1` flattens the global prefs
  and the active mode's slice into the one map the HUD and every LiveView
  assign reads, and `get_pref/2` / `put_pref/3` resolve a single key against
  the active mode. Switching mode therefore swaps level, karma and faction
  without any page knowing those values are namespaced.

  Progress (completions, watchlists, hideout) is namespaced the same way but
  lives in `localStorage`, not the cookie - see `EftBuddy.Progress`.

  ## Scav karma is stored in integer hundredths

  Karma ranges -6.00..+6.00 and the stepper nudges it by 0.1. Accumulating
  those steps as floats drifts (`0.1 + 0.2 != 0.3`), which is visible in a
  HUD that renders the value to two decimals. Internally karma is therefore
  an **integer count of hundredths** (-600..600); `karma_to_float/1` converts
  at the presentation edge and `parse(:scav_karma, _)` converts on the way in.
  """

  @min_level 1
  @max_level 79
  @default_level 1

  @default_mode :pvp
  @default_faction :usec

  # Karma, in integer hundredths (see moduledoc).
  @min_karma_cents -600
  @max_karma_cents 600
  @karma_step_cents 10
  @default_karma_cents 0

  # ── Which prefs are per-mode ───────────────────────────────────────
  #
  # PVP and PVE are separate progressions in-game, so the prefs that describe
  # *the operator's character* are stored once per mode. Only two prefs are
  # genuinely global: the mode selector itself (it chooses the slice, so it
  # can't live inside one) and the nav rail's collapsed state (pure chrome,
  # nothing to do with a profile).
  #
  # `:faction` is per-mode: USEC/BEAR is offered in both modes, so the choice
  # belongs to the profile rather than the browser.
  @global_pref_keys [:mode, :rail_collapsed]
  @mode_pref_keys [:pmc_level, :scav_karma, :faction]

  # The complete set of operator prefs, in the order the HUD presents them.
  # `parse/2` and `cookie_value/2` must have a clause for each.
  @pref_keys [:pmc_level, :mode, :faction, :scav_karma, :rail_collapsed]

  @game_modes [:pvp, :pve]

  @type pref_key :: :pmc_level | :mode | :faction | :scav_karma | :rail_collapsed
  @type game_mode :: :pvp | :pve
  @typedoc """
  A complete, canonical pref set: the global prefs plus one slice per game mode.

      %{
        mode: :pvp,
        rail_collapsed: false,
        modes: %{
          pvp: %{pmc_level: 12, scav_karma: 40, faction: :usec},
          pve: %{pmc_level: 1, scav_karma: 0, faction: :bear}
        }
      }
  """
  @type prefs :: %{
          :mode => game_mode(),
          :rail_collapsed => boolean(),
          :modes => %{game_mode() => %{pref_key() => term()}}
        }

  @doc "Every recognised operator-pref key."
  @spec pref_keys() :: [pref_key()]
  def pref_keys, do: @pref_keys

  @doc "The pref keys stored once per game mode."
  @spec mode_pref_keys() :: [pref_key()]
  def mode_pref_keys, do: @mode_pref_keys

  @doc "The pref keys shared across game modes."
  @spec global_pref_keys() :: [pref_key()]
  def global_pref_keys, do: @global_pref_keys

  @doc "Every game mode a pref set carries a slice for."
  @spec game_modes() :: [game_mode()]
  def game_modes, do: @game_modes

  @doc "True when `key` is a recognised operator pref."
  @spec pref_key?(term()) :: boolean()
  def pref_key?(key), do: key in @pref_keys

  @doc """
  The canonical default prefs for an operator we know nothing about.

  Note `:scav_karma` is in integer hundredths, like everywhere else inside
  this module.
  """
  @spec defaults() :: prefs()
  def defaults do
    %{
      mode: @default_mode,
      rail_collapsed: false,
      modes: Map.new(@game_modes, fn mode -> {mode, mode_defaults()} end)
    }
  end

  defp mode_defaults do
    %{
      pmc_level: @default_level,
      scav_karma: @default_karma_cents,
      faction: @default_faction
    }
  end

  @doc """
  Parse + clamp a single pref value into its canonical internal form.

  Returns `nil` when the value is missing or invalid, which every caller
  treats as "keep the current value". This is the *only* sanctioned way to
  turn untrusted input (cookie, form field, imported backup) into a pref.
  """
  @spec parse(pref_key(), term()) :: term() | nil
  def parse(:pmc_level, value) do
    case to_integer(value) do
      nil -> nil
      n -> n |> max(@min_level) |> min(@max_level)
    end
  end

  def parse(:mode, :pvp), do: :pvp
  def parse(:mode, :pve), do: :pve
  def parse(:mode, "pvp"), do: :pvp
  def parse(:mode, "pve"), do: :pve
  def parse(:mode, _), do: nil

  def parse(:faction, :usec), do: :usec
  def parse(:faction, :bear), do: :bear
  def parse(:faction, "usec"), do: :usec
  def parse(:faction, "bear"), do: :bear
  def parse(:faction, _), do: nil

  def parse(:scav_karma, value) do
    case to_karma_cents(value) do
      nil -> nil
      cents -> clamp_karma_cents(cents)
    end
  end

  def parse(:rail_collapsed, true), do: true
  def parse(:rail_collapsed, false), do: false
  def parse(:rail_collapsed, "true"), do: true
  def parse(:rail_collapsed, "false"), do: false
  def parse(:rail_collapsed, _), do: nil

  @doc """
  Parse a whole map of untrusted prefs into a **complete** canonical pref set.

  Accepts the nested, JSON-shaped payload the `eft_prefs` cookie carries (see
  `cookie_payload/1`) with string *or* atom keys. Unknown keys are dropped and
  any value that fails `parse/2` falls back to its default, so the result is
  always a full `t:prefs/0` - callers can use it directly instead of merging it
  over `defaults/0` (a shallow merge would replace the whole `:modes` map and
  lose the mode the payload didn't mention).
  """
  @spec parse_all(term()) :: prefs()
  def parse_all(raw) when is_map(raw) do
    slices = raw |> fetch_either(:modes) |> as_map()

    %{
      mode: parse_or_default(raw, :mode),
      rail_collapsed: parse_or_default(raw, :rail_collapsed),
      modes:
        Map.new(@game_modes, fn mode ->
          slice = slices |> fetch_either(mode) |> as_map()
          {mode, Map.new(@mode_pref_keys, fn key -> {key, parse_or_default(slice, key)} end)}
        end)
    }
  end

  def parse_all(_raw), do: defaults()

  defp parse_or_default(raw, key) do
    case parse(key, fetch_either(raw, key)) do
      nil -> default_for(key)
      value -> value
    end
  end

  defp default_for(:mode), do: @default_mode
  defp default_for(:rail_collapsed), do: false
  defp default_for(key), do: Map.fetch!(mode_defaults(), key)

  defp as_map(value) when is_map(value), do: value
  defp as_map(_value), do: %{}

  @doc """
  The prefs that apply *right now*, flattened: the global prefs plus the active
  mode's slice, as one map keyed by pref key.

  This is what the HUD and every page assign reads, which is why switching mode
  changes level / karma / faction without a single page knowing that those
  values are stored per mode.
  """
  @spec active(prefs()) :: %{pref_key() => term()}
  def active(prefs) do
    @global_pref_keys
    |> Map.new(fn key -> {key, Map.get(prefs, key, default_for(key))} end)
    |> Map.merge(mode_slice(prefs, Map.get(prefs, :mode, @default_mode)))
  end

  @doc "One mode's pref slice, falling back to defaults for anything missing."
  @spec mode_slice(prefs(), game_mode()) :: %{pref_key() => term()}
  def mode_slice(prefs, mode) do
    slice = prefs |> Map.get(:modes, %{}) |> Map.get(mode) |> as_map()
    Map.merge(mode_defaults(), Map.take(slice, @mode_pref_keys))
  end

  @doc """
  Read one pref's current value, resolving per-mode keys against the active mode.
  """
  @spec get_pref(prefs(), pref_key()) :: term()
  def get_pref(prefs, key) when key in @global_pref_keys,
    do: Map.get(prefs, key, default_for(key))

  def get_pref(prefs, key) when key in @mode_pref_keys do
    prefs |> mode_slice(Map.get(prefs, :mode, @default_mode)) |> Map.fetch!(key)
  end

  @doc """
  Write one **already-parsed** pref value, routing it to the global set or to
  the active mode's slice.
  """
  @spec put_pref(prefs(), pref_key(), term()) :: prefs()
  def put_pref(prefs, key, value) when key in @global_pref_keys, do: Map.put(prefs, key, value)

  def put_pref(prefs, key, value) when key in @mode_pref_keys do
    mode = Map.get(prefs, :mode, @default_mode)
    slice = prefs |> mode_slice(mode) |> Map.put(key, value)

    Map.put(prefs, :modes, prefs |> Map.get(:modes, %{}) |> Map.put(mode, slice))
  end

  @doc """
  The whole pref set as the JSON-safe, nested payload written to the
  `eft_prefs` cookie (and carried in an exported backup).

  Atoms become strings and karma a decimal number, so the value stays readable
  and writable by the JS side. The payload is a **complete snapshot**, not a
  patch: nesting means the browser can't shallow-merge one key without risking
  the other mode's slice, so the server always sends the lot.
  """
  @spec cookie_payload(prefs()) :: map()
  def cookie_payload(prefs) do
    globals =
      Map.new(@global_pref_keys, fn key ->
        {Atom.to_string(key), cookie_value(key, get_pref(prefs, key))}
      end)

    slices =
      Map.new(@game_modes, fn mode ->
        slice = mode_slice(prefs, mode)

        {Atom.to_string(mode),
         Map.new(@mode_pref_keys, fn key ->
           {Atom.to_string(key), cookie_value(key, Map.fetch!(slice, key))}
         end)}
      end)

    Map.put(globals, "modes", slices)
  end

  # The cookie carries string keys; internal callers use atoms. Accept both so
  # there is exactly one parsing path.
  defp fetch_either(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} -> value
      :error -> Map.get(raw, Atom.to_string(key))
    end
  end

  @doc """
  The JSON-safe representation of a pref, as written into the `eft_prefs`
  cookie by the client bridge.

  Atoms become strings and karma is emitted as a decimal number, so the cookie
  stays readable/writable by the JS side and by exported backups.
  """
  @spec cookie_value(pref_key(), term()) :: term()
  def cookie_value(:scav_karma, cents) when is_integer(cents), do: karma_to_float(cents)
  def cookie_value(:mode, mode) when is_atom(mode), do: Atom.to_string(mode)
  def cookie_value(:faction, faction) when is_atom(faction), do: Atom.to_string(faction)
  def cookie_value(_key, value), do: value

  @doc "Nudge karma (in hundredths) by one stepper detent, clamped to range."
  @spec step_karma(integer(), :up | :down) :: integer()
  def step_karma(cents, :up), do: clamp_karma_cents(cents + @karma_step_cents)
  def step_karma(cents, :down), do: clamp_karma_cents(cents - @karma_step_cents)

  @doc "Nudge the PMC level by one, clamped to range."
  @spec step_level(integer(), :up | :down) :: integer()
  def step_level(level, :up), do: min(level + 1, @max_level)
  def step_level(level, :down), do: max(level - 1, @min_level)

  @doc """
  Convert internal karma hundredths to the float the HUD renders.

  Rounded to two decimals so the readout never shows accumulated float noise.
  """
  @spec karma_to_float(integer()) :: float()
  def karma_to_float(cents) when is_integer(cents), do: Float.round(cents / 100, 2)

  @doc "Lowest legal PMC level."
  def min_level, do: @min_level
  @doc "Highest legal PMC level (the in-game cap)."
  def max_level, do: @max_level
  @doc "Lowest legal scav karma, as a float (for form `min=` attributes)."
  def min_karma, do: karma_to_float(@min_karma_cents)
  @doc "Highest legal scav karma, as a float (for form `max=` attributes)."
  def max_karma, do: karma_to_float(@max_karma_cents)

  defp clamp_karma_cents(cents) do
    cents |> max(@min_karma_cents) |> min(@max_karma_cents)
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp to_integer(_value), do: nil

  # Karma arrives as a JSON number (cookie) or a typed string (form field), in
  # whole karma units - e.g. `3`, `-1.4`, `"0.25"`. A whole-number value from
  # JSON deserialises as an integer (JS `JSON.stringify(0.0)` emits `0`), so
  # both numeric shapes mean the same thing and scale by 100. Floats are
  # rounded rather than truncated so 0.15 lands on 15, not 14.
  defp to_karma_cents(value) when is_integer(value), do: value * 100
  defp to_karma_cents(value) when is_float(value), do: round(value * 100)

  defp to_karma_cents(value) when is_binary(value) do
    case value |> String.trim() |> Float.parse() do
      {f, _rest} -> round(f * 100)
      :error -> nil
    end
  end

  defp to_karma_cents(_value), do: nil
end
