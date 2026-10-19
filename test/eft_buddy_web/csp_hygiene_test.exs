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

  test "every browser page carries the policy, and scripts come only from this site",
       %{conn: conn} do
    # Sobelow cannot evaluate the router's `@csp`, so its CSP check is skipped on
    # the pipeline. This is what stands in for it.
    for path <- [~p"/tasks", ~p"/items", ~p"/report-bug"] do
      [csp] = conn |> get(path) |> get_resp_header("content-security-policy")

      assert csp =~ "default-src 'self'", path
      assert csp =~ "script-src 'self'", path
      refute csp =~ ~r/script-src[^;]*'unsafe-inline'/, path
    end
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
