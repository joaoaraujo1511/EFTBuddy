defmodule EftBuddyWeb.TransportLogTest do
  use EftBuddyWeb.ConnCase, async: true

  import Plug.Test, only: [conn: 2]

  alias EftBuddyWeb.TransportLog

  @chrome "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/142.0 Safari/537.36"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

  defp request(path, user_agent \\ @chrome) do
    :get |> conn(path) |> put_req_header("user-agent", user_agent)
  end

  test "names the browser family" do
    for {user_agent, family} <- [
          {@chrome, "chrome"},
          {@iphone, "safari"},
          {"Mozilla/5.0 Chrome/142.0 Safari/537.36 Edg/142.0", "edge"},
          {"Mozilla/5.0 Chrome/142.0 Safari/537.36 OPR/120.0", "opera"},
          {"Mozilla/5.0 Gecko/20100101 Firefox/144.0", "firefox"},
          {"Mozilla/5.0 (compatible; Googlebot/2.1)", "bot"},
          {"", "other"}
        ] do
      assert TransportLog.browser(user_agent) == family
    end
  end

  test "logs the family and never the full user agent" do
    assert TransportLog.entry(request("/live/websocket?vsn=2.0.0", @iphone)) ==
             "[Transport] websocket safari mobile"
  end

  test "counts a long-poll client once, not on every poll" do
    first = request("/live/longpoll?vsn=2.0.0&_csrf_token=abc")
    repeat = request("/live/longpoll?vsn=2.0.0&_csrf_token=abc&token=xyz&sig=123")

    assert TransportLog.entry(first) == "[Transport] longpoll chrome"
    assert TransportLog.entry(repeat) == nil
  end

  test "a malformed query cannot break the request", %{conn: conn} do
    assert TransportLog.entry(request("/live/longpoll?%zz")) == "[Transport] longpoll chrome"
    assert get(conn, "/live/longpoll?vsn=2.0.0").status in [200, 403, 410]
  end
end
