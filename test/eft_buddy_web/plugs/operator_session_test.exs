defmodule EftBuddyWeb.Plugs.OperatorSessionTest do
  @moduledoc """
  The `eft_prefs` cookie is written by the browser, so the server must treat
  every byte of it as untrusted. The plug decodes it on every request, and
  `EftBuddy.Operator.parse_all/1` turns it into prefs for the first render, so
  a value either of them chokes on breaks every page for that browser, before
  any JS loads and therefore before the in-app Backup -> Reset could fix it.
  """
  use EftBuddyWeb.ConnCase, async: true

  alias EftBuddyWeb.Plugs.OperatorSession, as: SessionPlug

  defp with_prefs_cookie(conn, raw), do: put_req_cookie(conn, SessionPlug.prefs_key(), raw)

  defp encoded(prefs), do: prefs |> Jason.encode!() |> URI.encode_www_form()

  describe "a hostile eft_prefs cookie never takes the page down" do
    test "an absurd scav karma is clamped, not raised on", %{conn: conn} do
      # REGRESSION (audit H4): `round(1.0e308 * 100)` raised on every request.
      raw = encoded(%{"modes" => %{"pvp" => %{"scav_karma" => 1.0e308}}})

      conn = conn |> with_prefs_cookie(raw) |> get(~p"/tasks")

      assert html_response(conn, 200)
    end

    test "a cookie that is not valid percent-encoding is ignored", %{conn: conn} do
      conn = conn |> with_prefs_cookie("%E0%A4%A") |> get(~p"/tasks")

      assert html_response(conn, 200)
      refute get_session(conn, SessionPlug.prefs_key())
    end

    test "JSON that is not an object is ignored", %{conn: conn} do
      conn = conn |> with_prefs_cookie(encoded([1, 2, 3])) |> get(~p"/tasks")

      assert html_response(conn, 200)
      refute get_session(conn, SessionPlug.prefs_key())
    end

    test "an oversized cookie is ignored rather than bridged", %{conn: conn} do
      raw = encoded(%{"modes" => %{"pvp" => %{"faction" => String.duplicate("x", 2_000)}}})

      conn = conn |> with_prefs_cookie(raw) |> get(~p"/tasks")

      assert html_response(conn, 200)
      refute get_session(conn, SessionPlug.prefs_key())
    end
  end
end
