defmodule EftBuddy.Wiki.PageGaps do
  @moduledoc """
  What the scrape of the current page could not fetch: a section, an image
  batch, a licence batch, its contributor roster.

  A scraper keeps going past those (a page missing one section is still worth
  storing), but must not then record the page as current. `EftBuddy.Wiki.Sync`
  skips any page whose stored revision matches the wiki's, so a page stamped
  with its revision after a transient failure stayed incomplete until an editor
  next touched it, which can be months (audit H11). A page with gaps is stored
  without a revision instead, which already means "scrape it again next run".

  One page is scraped at a time, start to finish, in the sync's own process
  (`EftBuddy.Wiki.Dump.run/2` fetches, resolves and writes each page before the
  next), so the record is kept per process: `reset/0` when a page starts,
  `note/1` from wherever something failed, `gaps/0` when it is written.
  """

  @key {__MODULE__, :gaps}

  @doc "Start recording for a new page."
  @spec reset() :: :ok
  def reset do
    Process.put(@key, [])
    :ok
  end

  @doc "Record something the current page's scrape could not fetch."
  @spec note(term()) :: :ok
  def note(what) do
    Process.put(@key, [what | Process.get(@key, [])])
    :ok
  end

  @doc "Everything recorded since the last `reset/0`, oldest first."
  @spec gaps() :: [term()]
  def gaps, do: @key |> Process.get([]) |> Enum.reverse()
end
