defmodule EftBuddyWeb.CspHygieneTest do
  @moduledoc """
  CSP hygiene (audit L29).

  The policy keeps `style-src 'unsafe-inline'` only for genuinely dynamic values
  (progress-bar widths, mask URLs); a fixed style belongs in a class, so that one
  day the allowance can be narrowed. Fixed inline styles had crept back in
  (23 Ammo column widths, an item tile's palette background, five hidden
  image-fallback placeholders), and there was no `form-action` directive.
  """
  use EftBuddyWeb.ConnCase, async: true

  test "the policy restricts where forms can submit", %{conn: conn} do
    [csp] = conn |> get(~p"/report-bug") |> get_resp_header("content-security-policy")

    assert csp =~ "form-action 'self'"
  end

  test "no template carries a static inline style" do
    # `style={...}` (computed) is allowed; `style="..."` (a fixed value) is not.
    offenders =
      for path <- Path.wildcard("lib/eft_buddy_web/**/*.{ex,heex}"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/\bstyle="/,
          do: "#{path}:#{n}"

    assert offenders == [], "use a class for fixed styles:\n" <> Enum.join(offenders, "\n")
  end
end
