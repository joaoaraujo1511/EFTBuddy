defmodule EftBuddyWeb.ErrorHTMLTest do
  use EftBuddyWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  # `EftBuddyWeb.ErrorHTML` no longer returns Phoenix's plain-text status
  # message — it renders a self-contained, themed OPERATOR-HUD page (see the
  # module doc). Phoenix renders error templates with a change-tracked
  # assigns map (`%{__changed__: nil, ...}`, see Phoenix's render_errors), so
  # we pass one here too rather than the empty `[]` the generator used.

  test "renders 404.html" do
    html = render_to_string(EftBuddyWeb.ErrorHTML, "404", "html", %{__changed__: nil})

    assert html =~ "404"
    assert html =~ "Signal Lost"
  end

  test "renders 500.html" do
    html = render_to_string(EftBuddyWeb.ErrorHTML, "500", "html", %{__changed__: nil})

    assert html =~ "500"
    assert html =~ "System Fault"
  end
end
