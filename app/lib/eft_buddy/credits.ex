defmodule EftBuddy.Credits do
  @moduledoc """
  Presentation helpers for wiki contributor credits.

  `EftBuddy.Wiki.Contributors` writes a per-page roster into each scraped
  manifest; the projections expose it; the credit line under each guide
  renders it (`EftBuddyWeb.CoreComponents.source_credit/1`). This module
  covers the small amount of shaping that sits between: splitting a roster
  into a first page and a remainder for the popup, deriving the monogram
  tile, and building the outbound links each name points at.

  ## No aggregate roster

  There used to be a `roster/0` here that unioned the contributor arrays out
  of every wiki-derived table to render one site-wide list on the credits
  page. That list is gone: credit belongs next to the content it applies to,
  which is the per-page popup, and a flat list of ~1,850 names served nobody
  well. The queries went with it — recoverable from git history if a
  contributor-first feature ever wants them.

  Profiles are linked, never ingested: over half of sampled contributors have
  nothing filled in, half share the default avatar, and mirroring any of it
  would mean holding third-party personal data.
  """

  @wiki_base "https://escapefromtarkov.fandom.com/wiki/"

  @doc """
  The contributor's Fandom profile — avatar, bio and any social links they
  chose to publish.

  Deliberately a link rather than data we mirror: over half of sampled
  contributors have nothing filled in, half share the default avatar, and
  copying any of it would mean holding third-party personal data. Fandom
  renders it, always current, at no cost to us.
  """
  @spec profile_url(String.t()) :: String.t()
  def profile_url(name) when is_binary(name), do: @wiki_base <> "UserProfile:" <> slug(name)

  @doc "The contributor's uploads, linked from the per-image credit."
  @spec uploads_url(String.t()) :: String.t()
  def uploads_url(name) when is_binary(name),
    do: @wiki_base <> "Special:ListFiles/" <> slug(name)

  @doc """
  Split names into a first page and the remainder for an inline credit popup.

  `rest` is returned rather than only a count because the popup expands in
  place: the names are already loaded, so revealing the rest is a class
  toggle instead of another request or a trip to a different page.
  """
  @spec preview([String.t()], pos_integer()) ::
          %{
            shown: [String.t()],
            rest: [String.t()],
            remaining: non_neg_integer(),
            total: non_neg_integer()
          }
  def preview(names, limit \\ 12) when is_list(names) and is_integer(limit) and limit > 0 do
    {shown, rest} = Enum.split(names, limit)

    %{
      shown: shown,
      rest: rest,
      remaining: length(rest),
      total: length(names)
    }
  end

  @doc """
  Initials for a contributor's monogram tile.

  Two characters at most, taken from the first two words when the name has
  them, otherwise the first two characters. Falls back to `"?"` so a
  malformed name still renders a tile instead of an empty box.
  """
  @spec initials(String.t()) :: String.t()
  def initials(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.split(~r/[\s_\-]+/, trim: true)
    |> case do
      [] -> "?"
      [one] -> one |> String.slice(0, 2) |> String.upcase()
      [a, b | _] -> (String.first(a) <> String.first(b)) |> String.upcase()
    end
  end

  @doc """
  A stable palette slot (0-5) for a contributor's monogram.

  Derived from the name so the same person is the same colour everywhere in
  the app, with no state to store.
  """
  @spec color_index(String.t()) :: non_neg_integer()
  def color_index(name) when is_binary(name), do: :erlang.phash2(name, 6)

  defp slug(name), do: name |> String.trim() |> String.replace(" ", "_") |> URI.encode()
end
