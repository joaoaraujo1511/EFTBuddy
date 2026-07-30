defmodule EftBuddy.GameMode do
  @moduledoc """
  Canonical helpers for the PVP/PVE game-mode discriminator.

  Two representations exist in the codebase and this module is the
  single bridge between them:

    * **DB / API form** — the strings `"regular"` and `"pve"`. These
      are exactly the values the tarkov.dev GraphQL `gameMode` argument
      accepts, and the values we store in the `game_mode` columns
      (`tasks`, `item_prices`, `sell_for`, `buy_for`, `items_barters`).
      Using the API's own spelling means the sync code can pass the
      stored value straight into a query without translation.

    * **UI form** — the atoms `:pvp` and `:pve`, owned by
      `EftBuddyWeb.OperatorState` (held in the operator's
      `EftBuddy.OperatorSession` and backed up to the `eft_prefs`
      cookie). `:pvp` maps to the API's `"regular"`.

  Everything else (contexts, sync, LiveViews) should funnel through
  `to_db/1` so the `:pvp <-> "regular"` asymmetry lives in exactly one
  place.
  """

  @regular "regular"
  @pve "pve"

  @typedoc "The DB/API game-mode discriminator."
  @type t :: String.t()

  @doc "The default mode used for legacy rows and as a fallback (`\"regular\"`)."
  @spec default() :: t()
  def default, do: @regular

  @doc "Every game mode we sync, in cold-start order (regular first)."
  @spec all() :: [t()]
  def all, do: [@regular, @pve]

  @doc """
  Normalise any input — a sidebar atom (`:pvp`/`:pve`), a DB string
  (`"regular"`/`"pve"`), or the friendly aliases `"pvp"`/`:regular` —
  to the canonical DB/API string. Anything unrecognised falls back to
  the default (`"regular"`) so a stale cookie or bad param can never
  produce an invalid `gameMode`.
  """
  @spec to_db(any()) :: t()
  def to_db(:pvp), do: @regular
  def to_db(:regular), do: @regular
  def to_db(:pve), do: @pve
  def to_db("regular"), do: @regular
  def to_db("pvp"), do: @regular
  def to_db("pve"), do: @pve
  def to_db(_), do: @regular

  @doc """
  Map a DB/API game-mode string back to the sidebar atom
  (`"regular" -> :pvp`, `"pve" -> :pve`). Useful when a context needs
  to echo the active mode back to the UI.
  """
  @spec to_sidebar(t()) :: :pvp | :pve
  def to_sidebar(@pve), do: :pve
  def to_sidebar(_), do: :pvp
end
