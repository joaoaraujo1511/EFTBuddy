defmodule EftBuddyWeb.RedirectController do
  @moduledoc """
  Tiny module plug for static, router-level redirects.

  Used to point the bare root (`/`) at the Tasks page, which is now the
  app's landing page (the old Home tab was removed). Kept as a plug rather
  than a live route so the browser URL settles on the canonical `/tasks`.
  """
  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, to: to) do
    conn
    |> Phoenix.Controller.redirect(to: to)
    |> halt()
  end
end
