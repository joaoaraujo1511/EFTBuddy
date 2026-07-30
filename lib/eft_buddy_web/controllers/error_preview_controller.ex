defmodule EftBuddyWeb.ErrorPreviewController do
  @moduledoc """
  Dev-only preview of the themed error pages (`EftBuddyWeb.ErrorHTML`).

  In development, `config/dev.exs` sets `debug_errors: true`, so a real 404
  or crash shows Phoenix's interactive debug page instead of the themed
  OPERATOR-HUD error page that production visitors actually get. That means
  the styled error page is otherwise invisible locally and easy to let rot.

  This controller renders it directly at `/dev/errors/:code`
  (e.g. `/dev/errors/404`, `/dev/errors/500`, `/dev/errors/503`) so the exact
  page a production visitor would see can be reviewed and tweaked without
  shipping to prod or toggling `debug_errors`. It is wired only inside the
  `dev_routes`-gated router scope, so it never exists in production.
  """
  use EftBuddyWeb, :controller

  # Render the themed page for the requested status code. `ErrorHTML.render/2`
  # keys off the `"<code>.html"` template name and falls back to a generic
  # styled page for anything it doesn't have bespoke copy for, so any code is
  # safe to preview. We serve it with the real status code so the preview is
  # faithful (a 404 preview responds 404, etc.).
  #
  # Sobelow flags `send_resp/3` with a non-literal body as possible XSS. It is a
  # false positive here on three counts, so it is annotated rather than worked
  # around: (1) `body` is the output of `ErrorHTML.render/2` piped through
  # `Phoenix.HTML.Safe.to_iodata/1`, i.e. already-escaped safe iodata;
  # (2) the ONLY user-supplied value, `code`, never reaches the body — it goes
  # through `parse_status/1`, which returns an integer clamped to 100..599;
  # (3) the route exists only inside the `Application.compile_env(:eft_buddy,
  # :dev_routes)` scope, so it is not compiled into a production build at all.
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"code" => code}) do
    status = parse_status(code)

    # `ErrorHTML.page/4` calls `Phoenix.Component.assign/3`, which requires an
    # assigns map carrying a `__changed__` key - a bare `%{}` raises. Seed it
    # so the render works exactly as it does in the real error pipeline.
    body =
      "#{status}.html"
      |> EftBuddyWeb.ErrorHTML.render(%{__changed__: nil})
      |> Phoenix.HTML.Safe.to_iodata()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  # Clamp to a sane HTTP status; anything unparseable previews as a 500.
  defp parse_status(code) do
    case Integer.parse(to_string(code)) do
      {n, _} when n >= 100 and n <= 599 -> n
      _ -> 500
    end
  end
end
