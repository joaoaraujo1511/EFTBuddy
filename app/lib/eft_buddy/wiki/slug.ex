defmodule EftBuddy.Wiki.Slug do
  @moduledoc """
  Shared slug helpers for the wiki dump pipelines.

  Both the quest pipeline (`EftBuddy.Wiki.Dump`) and the storyline
  pipeline (`EftBuddy.Chapters.Dump`) need to derive two kinds of slug
  from wiki text:

    * `normalize_name/1` — a dash-joined slug used to key a wiki page to
      a DB record (a task's `normalized_name`, or a related-link target).
      It is **transliteration-aware**: accented characters are folded to
      their ASCII base (`é` → `e`, `ä` → `a`) before slugging, so the
      slug matches tarkov.dev's `normalizedName` (which transliterates)
      rather than dropping the accent entirely. Without this, a quest
      like "Café" produced `"caf"` here but `"cafe"` from the API, which
      falsely flagged the quest WIP and broke cross-linking.

    * `slugify/1` — an underscore-joined, length-bounded slug used as a
      stable per-section anchor id.

  These were previously copy-pasted byte-for-byte across the two `Dump`
  modules; centralising them keeps the two pipelines genuinely symmetric.
  """

  @doc """
  Lowercase, dash-joined, transliteration-aware slug derived from a name.

  Folds accents to ASCII (so it matches tarkov.dev's `normalizedName`),
  lowercases, replaces every run of non-alphanumeric characters with a
  single dash, and trims leading/trailing dashes.
  """
  @spec normalize_name(String.t()) :: String.t()
  def normalize_name(name) when is_binary(name) do
    name
    |> fold_accents()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Lowercase, underscore-joined, length-bounded (≤60 byte) slug for use
  as a per-section anchor id.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> truncate_slug(60)
  end

  @doc """
  Truncate a `_`-joined slug to at most `max` bytes, preferring to cut on
  an underscore boundary (when that boundary is past the halfway point)
  so we don't leave a dangling partial word.
  """
  @spec truncate_slug(String.t(), pos_integer()) :: String.t()
  def truncate_slug(s, max) when byte_size(s) <= max, do: s

  def truncate_slug(s, max) do
    head = String.slice(s, 0, max)

    case :binary.matches(head, "_") do
      [] ->
        head

      matches ->
        {last_underscore, _} = List.last(matches)
        if last_underscore >= div(max, 2), do: String.slice(head, 0, last_underscore), else: head
    end
  end

  # Decompose to NFD then drop the combining marks (Unicode block
  # U+0300..U+036F), turning "é" into "e", "ü" into "u", etc. ASCII text
  # is unaffected. This mirrors the transliteration tarkov.dev applies
  # when it builds `normalizedName`.
  defp fold_accents(s) do
    s
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[\x{0300}-\x{036F}]/u, "")
  end
end
