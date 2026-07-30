defmodule EftBuddyWeb.PageController do
  @moduledoc """
  Static, content-only pages that have no state and no interactivity.

  Currently just `/privacy`. Deliberately a plain controller rather than a
  LiveView: there is nothing to update, and a LiveView would open a WebSocket
  and mint an `EftBuddy.OperatorSession` for a page that is pure prose.
  """
  use EftBuddyWeb, :controller

  def privacy(conn, _params) do
    render(conn, :privacy, page_title: "Privacy")
  end
end
