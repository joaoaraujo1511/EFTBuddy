defmodule EftBuddyWeb.Format do
  @moduledoc """
  Small, shared presentation formatters used across LiveViews and templates.

  Centralises number/duration formatting that was previously copy-pasted in
  several LiveViews (Home, Hideout, Flea Market, Maps). Imported globally via
  `EftBuddyWeb.html_helpers/0`, so `thousands/1` and `raid_duration_label/1`
  are available unqualified in every template.
  """

  @doc """
  Groups an integer with comma thousands separators, e.g.
  `1_234_567 -> "1,234,567"`. Negative integers keep their sign; anything
  that isn't an integer renders as a dash (`"-"`).
  """
  def thousands(n) when is_integer(n) and n < 0, do: "-" <> thousands(-n)

  def thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def thousands(_), do: "-"

  @doc """
  Human raid-duration label. The tarkov.dev API gives minutes; `nil` and
  non-positive values (some event maps report `-1`) render as a dash.
  """
  def raid_duration_label(minutes) when is_integer(minutes) and minutes > 0, do: "#{minutes} min"
  def raid_duration_label(_), do: "-"

  # ── Found-in-raid text highlighting ────────────────────

  # Matches the found-in-raid cue anywhere in a string, case-insensitively.
  # Two phrasings occur across the app's copy: the full "found in raid" (item
  # descriptions, the generated quest sentences) and the bare "in raid" (many
  # API objective texts, e.g. "Hand over ... in raid"). The full phrase is
  # listed first so the alternation captures it whole rather than leaving a
  # stray "found " in front of a highlighted "in raid". The bare alternative
  # is word-bounded so it never highlights mid-word (e.g. "cert*ain raid*ers"
  # or "m*ain raid*").
  @fir_regex ~r/found in raid|\bin raid\b/i
  @fir_exact ~r/\A(?:found in raid|in raid)\z/i

  @doc """
  Return `text` as HEEx-renderable iodata with every "found in raid" / "in
  raid" occurrence wrapped in a red `<span>` (matching the official EFT wiki's
  treatment of the phrase), leaving the rest of the copy untouched. Shared by
  the Items and Tasks pages so found-in-raid requirements and objectives read
  identically. Interpolate it directly: `{fir_text(some_text)}`.

  Splits on the phrase (keeping the matches) and emits each segment as either
  the plain (still auto-escaped by HEEx) text run or a safe red `<span>`. Only
  the fixed span markup is marked safe - the caller's text is never - so an
  untrusted item description or objective can't inject markup. Original casing
  and surrounding whitespace are preserved, so it drops cleanly into a
  `whitespace-pre-line` paragraph without adding stray spaces or line breaks.
  A nil / non-binary value renders nothing.

  Implemented as a plain function returning iodata (rather than a function
  component) so the interpolation introduces no template whitespace around the
  highlighted phrase.
  """
  @fir_open Phoenix.HTML.raw(~s(<span class="text-rust font-semibold">))
  @fir_close Phoenix.HTML.raw("</span>")

  def fir_text(text) when is_binary(text) do
    @fir_regex
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      if Regex.match?(@fir_exact, part),
        do: [@fir_open, part, @fir_close],
        else: part
    end)
  end

  def fir_text(_), do: []
end
