defmodule EftBuddyWeb.LongPollCapTest do
  @moduledoc """
  The long-poll transport now has the same per-request cap as a WebSocket frame
  (audit M27). It used to accept about 8 MB per POST, up to 100 messages, while
  the endpoint's comment said the 1 MB `max_frame_size` bounded what an
  unauthenticated client could push, and most clients on the Pi long-poll.
  """
  use EftBuddyWeb.ConnCase, async: true

  alias EftBuddyWeb.Endpoint

  defp longpoll(conn, body, length) do
    conn
    |> then(&if(length, do: put_req_header(&1, "content-length", to_string(length)), else: &1))
    |> put_req_header("content-type", "application/x-ndjson")
    |> post("/live/longpoll", body)
  end

  test "a body over the frame cap is refused before the transport reads it", %{conn: conn} do
    big = Endpoint.max_frame_size() + 1

    assert longpoll(conn, "x", big).status == 413
  end

  test "a body without a length is refused", %{conn: conn} do
    assert longpoll(conn, "x", nil).status == 411
  end

  test "a body within the cap reaches the long-poll transport", %{conn: conn} do
    # No session token, so the transport itself answers; what matters is that
    # it was the transport, not the cap.
    status = longpoll(conn, ~s([null,null,"phoenix","heartbeat",{}]), 40).status

    refute status in [411, 413]
  end

  test "the cap is the WebSocket frame size", %{conn: _conn} do
    assert Endpoint.max_frame_size() == 1024 * 1024
  end

  test "other routes are untouched", %{conn: conn} do
    assert get(conn, "/health").status == 200
  end
end
