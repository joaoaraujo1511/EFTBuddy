defmodule EftBuddy.Wiki.Markup do
  @moduledoc """
  Shared helpers for turning raw MediaWiki wikitext fragments into plain,
  display-ready text.

  Used across the quest dump (`EftBuddy.Wiki.Dump`), the quest
  projection (`EftBuddy.Wiki.Projection`), the storyline dump
  (`EftBuddy.Chapters.Dump`), and the storyline section parser
  (`EftBuddy.Chapters.SectionParser`) so the cleaning rules and
  low-level wikitext primitives live in exactly one place. Previously
  each module carried its own copy, which had already drifted (the
  bold/italic stripping fix below existed in only one of them).

  All functions are pure and string-in/string-out.
  """

  @doc """
  Strip wiki/template/HTML markup from a fragment and collapse
  whitespace: removes `{{templates}}`, `<html>` tags, resolves
  `[[links]]`, drops bold/italic markers, and trims.
  """
  @spec clean_text(term()) :: String.t()
  def clean_text(text) when is_binary(text) do
    text
    |> strip_templates_repeatedly()
    |> strip_html_tags()
    |> normalize_inline_wiki_markup()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def clean_text(_), do: ""

  @doc "Remove `<!-- ... -->` HTML comments (across newlines)."
  @spec strip_html_comments(String.t()) :: String.t()
  def strip_html_comments(s), do: String.replace(s, ~r/<!--.*?-->/s, "")

  @doc "Remove `<nowiki>...</nowiki>` wrappers and their contents."
  @spec strip_nowiki(String.t()) :: String.t()
  def strip_nowiki(s), do: String.replace(s, ~r/<nowiki>.*?<\/nowiki>/si, "")

  @doc "Strip any `<...>` HTML tag, leaving the inner text."
  @spec strip_html_tags(String.t()) :: String.t()
  def strip_html_tags(s), do: Regex.replace(~r/<[^>]+>/, s, "")

  @doc """
  Remove inline `[[File:...]]` / `[[Image:...]]` references (including a
  single level of nested `[[...]]` inside the caption) and collapse the
  resulting whitespace.
  """
  @spec strip_inline_file_refs(String.t()) :: String.t()
  def strip_inline_file_refs(text) do
    text
    |> String.replace(~r/\[\[(?:File|Image):[^\]\[]*(?:\[\[[^\]]+\]\][^\]\[]*)*\]\]/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Resolve inline wikilinks and drop emphasis markers:

    * `[[Foo|Bar]]` → `Bar`, `[[Foo]]` → `Foo`
    * `'''bold'''` / `''italic''` → plain text

  The bold/italic markers are removed as raw `'''`/`''` runs rather than
  matched as `'''(...)'''`, so emphasised text that itself contains an
  apostrophe (e.g. "didn't") is still cleaned.
  """
  @spec normalize_inline_wiki_markup(String.t()) :: String.t()
  def normalize_inline_wiki_markup(s) do
    s = Regex.replace(~r/\[\[([^\|\]]+)\|([^\]]+)\]\]/, s, "\\2")
    s = Regex.replace(~r/\[\[([^\]]+)\]\]/, s, "\\1")

    s
    |> String.replace("'''''", "")
    |> String.replace("'''", "")
    |> String.replace("''", "")
  end

  @doc """
  True when a cleaned paragraph is residual category-link / interwiki
  metadata rather than real prose (e.g. `"Category:Quests"`,
  `"cs:Zlatý lup"`, or a collapsed interlanguage block like
  `"FR:Swag - Partie 1 cs:… ru:…"`), which survives the markup-strip pass
  but isn't intro material.

  The interwiki/interlanguage prefix is matched case-insensitively:
  MediaWiki language codes appear in both cases (`fr:` / `FR:`), and the
  bottom-of-page interlanguage links collapse into one paragraph that
  begins with such a prefix.
  """
  @spec metadata_paragraph?(String.t()) :: boolean()
  def metadata_paragraph?(p) when is_binary(p) do
    String.starts_with?(p, "Category:") or Regex.match?(~r/^[a-z]{2,3}:\S/iu, p)
  end

  @doc """
  Scan a wikilink body starting just past an opening `[[` at byte
  `pos`, honouring nested `[[ ... ]]`.

  Returns `{:ok, inner, after_pos}` where `inner` is the text between the
  outer brackets and `after_pos` is the byte index just past the closing
  `]]`, or `:error` if the link is unterminated.
  """
  @spec scan_wikilink(binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | :error
  def scan_wikilink(line, pos), do: scan_wikilink(line, pos, 1, pos)

  defp scan_wikilink(line, pos, _depth, _start) when pos >= byte_size(line), do: :error

  defp scan_wikilink(line, pos, depth, start) do
    rest_size = byte_size(line) - pos
    chunk = :binary.part(line, pos, min(2, rest_size))

    cond do
      chunk == "[[" ->
        scan_wikilink(line, pos + 2, depth + 1, start)

      chunk == "]]" and depth == 1 ->
        inner = :binary.part(line, start, pos - start)
        {:ok, inner, pos + 2}

      chunk == "]]" ->
        scan_wikilink(line, pos + 2, depth - 1, start)

      true ->
        scan_wikilink(line, pos + 1, depth, start)
    end
  end

  @doc """
  Split a wikilink body on top-level `|` pipes, ignoring pipes that sit
  inside a nested `[[ ... ]]` (so `[[A|B]]` captions don't get split).
  """
  @spec split_pipes_depth_aware(binary()) :: [binary()]
  def split_pipes_depth_aware(s) do
    chars = String.to_charlist(s)

    {parts, current, _depth} =
      Enum.reduce(chars, {[], [], 0}, fn
        ?[, {parts, [?[ | _] = current, depth} ->
          {parts, [?[ | current], depth + 1}

        ?[, {parts, current, depth} ->
          {parts, [?[ | current], depth}

        ?], {parts, [?] | _] = current, depth} when depth > 0 ->
          {parts, [?] | current], depth - 1}

        ?], {parts, current, depth} ->
          {parts, [?] | current], depth}

        ?|, {parts, current, 0} ->
          {[Enum.reverse(current) |> List.to_string() | parts], [], 0}

        ch, {parts, current, depth} ->
          {parts, [ch | current], depth}
      end)

    Enum.reverse([Enum.reverse(current) |> List.to_string() | parts])
  end

  # Remove `{{...}}` templates, innermost-first, until none remain (so
  # nested templates are fully cleared).
  defp strip_templates_repeatedly(s) do
    case Regex.replace(~r/\{\{[^{}]*\}\}/, s, "") do
      ^s -> s
      replaced -> strip_templates_repeatedly(replaced)
    end
  end
end
