defmodule EftBuddy.Items.BackgroundColor do
  @moduledoc """
  Maps the small enumerated `backgroundColor` token returned by
  tarkov.dev (e.g. `"blue"`, `"violet"`, `"yellow"`) onto the CSS
  color used by the in-game inventory tile.

  Used by the items LiveView to paint a tile background behind the
  high-resolution `image_512px_link` so we can render bigger icons
  without losing the tier-color cue that the small `icon_link` PNG
  bakes in.

  The palette is the game's own inventory-cell colours. tarkov.dev's
  item-image generator paints a per-`backgroundColor` RGB tint at a
  fixed 77/255 (~30%) alpha over the dark inventory cell
  (`rgb(39,39,39)`). We pre-composite that exact overlay here and
  store the resulting solid hex, so a tile painted behind a
  transparent `image_512px_link` matches the cell colour baked into
  tarkov.dev's own item images — i.e. what the item looks like
  in-game.

  Source RGB tints + alpha: tarkov.dev's image generator
  ([image-functions.js]).

  [image-functions.js]: https://github.com/the-hideout/tarkov-dev-image-generator/blob/master/image-functions.js
  """

  # Token → CSS color. Each value is the game's per-rarity overlay
  # RGB (from tarkov.dev's image generator) composited at its real
  # 77/255 (~30%) alpha over the dark inventory cell rgb(39,39,39),
  # i.e. the exact colour the cell shows in-game. Unknown / new
  # tokens fall through to `@fallback` and still render fine.
  @colors %{
    "default" => "#424242",
    "black" => "#1b1b1b",
    "blue" => "#242f35",
    "green" => "#22291b",
    "grey" => "#242424",
    "orange" => "#2d231b",
    "red" => "#3c2622",
    "violet" => "#322835",
    "yellow" => "#3b3a27"
  }

  # Same as the `default` tier — keeps unknown / missing values
  # visually consistent with the palette rather than dropping to
  # pure black.
  @fallback "#424242"

  @doc """
  Returns the CSS color string for a tier token, or a neutral
  fallback for `nil` / unknown values. Always safe to interpolate
  into a `style=` attribute.
  """
  @spec css(String.t() | nil) :: String.t()
  def css(nil), do: @fallback
  def css(token) when is_binary(token), do: Map.get(@colors, token, @fallback)
  def css(_), do: @fallback

  @doc """
  Returns the CSS utility class for a tier token (e.g. `"item-bg-blue"`),
  falling back to `"item-bg-default"` for `nil` / unknown values.

  Pairs with the hand-written `.item-bg-*` rules in `assets/css/app.css`,
  so an item tile can set its tier background via a class instead of an
  inline `style` attribute. Always safe to drop straight into a `class`
  list.
  """
  @spec class(String.t() | nil) :: String.t()
  def class(token) when is_binary(token) do
    if Map.has_key?(@colors, token), do: "item-bg-#{token}", else: "item-bg-default"
  end

  def class(_), do: "item-bg-default"

  @doc """
  All known tier tokens. Useful for tests / introspection.
  """
  @spec known() :: [String.t()]
  def known, do: Map.keys(@colors)
end
