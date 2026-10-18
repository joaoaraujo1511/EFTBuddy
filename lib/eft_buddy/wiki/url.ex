defmodule EftBuddy.Wiki.Url do
  @moduledoc """
  Links to pages on the EFT Fandom wiki, encoded the way MediaWiki encodes them.

  A source link is the "URI to the material" that CC BY-NC-SA attribution
  requires, so a broken one breaks the attribution. Five places built them by
  replacing spaces with underscores and nothing more, which leaves `?`, `#`, `&`
  and `%` in a title as URL syntax: a quest titled "Are you going to eat
  that?" linked to the page "Are_you_going_to_eat_that" (audit M20).

  `page/1` is the one encoder. `normalize/1` repairs a link stored before it
  existed: the projections run every stored link through it, because the quest
  scrape skips unchanged pages, so stored links would otherwise stay broken
  until each page was next edited.
  """

  @base "https://escapefromtarkov.fandom.com/wiki/"

  # What MediaWiki's own `wfUrlencode` leaves unescaped in a page path, on top
  # of the RFC 3986 unreserved characters.
  @keep ~c";@$!*(),/~:"

  @doc """
  The URL of the wiki page titled `title`.

      iex> EftBuddy.Wiki.Url.page("Are you going to eat that?")
      "https://escapefromtarkov.fandom.com/wiki/Are_you_going_to_eat_that%3F"

      iex> EftBuddy.Wiki.Url.page("UserProfile:Some User")
      "https://escapefromtarkov.fandom.com/wiki/UserProfile:Some_User"
  """
  @spec page(String.t()) :: String.t()
  def page(title) when is_binary(title), do: @base <> encode_title(title)

  @doc """
  Re-encode a stored wiki link, whether it was stored encoded or not. Links
  elsewhere, and `nil`, pass through unchanged.

      iex> EftBuddy.Wiki.Url.normalize("https://escapefromtarkov.fandom.com/wiki/Gunsmith_-_Part_1?")
      "https://escapefromtarkov.fandom.com/wiki/Gunsmith_-_Part_1%3F"

      iex> EftBuddy.Wiki.Url.normalize("https://escapefromtarkov.fandom.com/wiki/Gunsmith_-_Part_1%3F")
      "https://escapefromtarkov.fandom.com/wiki/Gunsmith_-_Part_1%3F"
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(@base <> path), do: @base <> encode_title(decode(path))
  def normalize(other), do: other

  defp encode_title(title) do
    title
    |> String.trim()
    |> String.replace(" ", "_")
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 in @keep))
  end

  # Decoding first is what makes `normalize/1` idempotent. A stored raw title
  # can contain a `%` that is not an escape ("100% Done"), which `URI.decode/1`
  # rejects; that title was never encoded, so it is used as it is.
  defp decode(path) do
    URI.decode(path)
  rescue
    ArgumentError -> path
  end
end
