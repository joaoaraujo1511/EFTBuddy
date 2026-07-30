defmodule EftBuddy.Repo.Migrations.AddBackgroundColorToItems do
  @moduledoc """
  Add `background_color` to items: the in-game inventory tier color
  token (e.g. "blue", "violet", "yellow") returned by tarkov.dev as
  the `backgroundColor` field on the `Item` type.

  Used by the LiveView to paint a tile background behind the
  high-resolution `image_512px_link` so we can render bigger icons
  without losing the tier-color cue that the small `icon_link`
  PNG bakes in.

  Stored as a short string (the canonical palette is ~9 tokens) and
  mapped to a CSS hex value by `EftBuddy.Items.BackgroundColor` at
  render time. Nullable so a missing API value (or an item synced
  before this column existed) just falls back to the neutral tile.

  Supersedes the rolled-back `icon_background_color` column from
  20260522120000 / 20260522170000 — that approach sampled pixels
  off the icon PNGs at sync time and was both flaky and approximate.
  Pulling the canonical tier token off the API removes both problems.
  """

  use Ecto.Migration

  def change do
    alter table(:items) do
      add(:background_color, :string, size: 16)
    end
  end
end
