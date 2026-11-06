defmodule EftBuddyWeb.TransportLog do
  @moduledoc """
  Temporary. Logs the transport and browser family of each new LiveView
  connection, to show which browsers fall back to long-polling. Only the family
  is logged, never the full user agent.

  Remove this module and its `@before_compile` line in the endpoint after
  2026-11-20.

  It wraps `call/2` for the same reason `EftBuddyWeb.LongPollCap` does: socket
  dispatch runs before any plug declared in the endpoint.
  """

  require Logger

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(%Plug.Conn{method: "GET", path_info: ["live", _]} = conn, opts) do
        EftBuddyWeb.TransportLog.log(conn)
        super(conn, opts)
      end

      def call(conn, opts), do: super(conn, opts)
    end
  end

  @doc false
  @spec log(Plug.Conn.t()) :: :ok
  def log(conn) do
    case entry(conn) do
      nil -> :ok
      line -> Logger.info(line)
    end
  end

  @doc false
  # The log line for a new connection, or `nil` for anything else. A long-poll
  # client repeats its GET with a `token` param for as long as it stays connected,
  # so only the first GET counts. The query is matched rather than decoded because
  # decoding raises on malformed input, and this runs before anything validates it.
  @spec entry(Plug.Conn.t()) :: String.t() | nil
  def entry(%Plug.Conn{path_info: ["live", "websocket"]} = conn), do: line("websocket", conn)

  def entry(%Plug.Conn{path_info: ["live", "longpoll"], query_string: query} = conn) do
    if Regex.match?(~r/(^|&)token=/, query), do: nil, else: line("longpoll", conn)
  end

  def entry(_conn), do: nil

  defp line(transport, conn) do
    user_agent = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
    "[Transport] #{transport} #{browser(user_agent)}#{if mobile?(user_agent), do: " mobile"}"
  end

  @doc false
  # Order matters: Edge and Opera also claim Chrome, and Chrome also claims Safari.
  @spec browser(String.t()) :: String.t()
  def browser(user_agent) do
    cond do
      user_agent =~ ~r/bot|crawl|spider|headless|preview|lighthouse/i -> "bot"
      user_agent =~ ~r/Edg/ -> "edge"
      user_agent =~ ~r/OPR|Opera/ -> "opera"
      user_agent =~ ~r/SamsungBrowser/ -> "samsung"
      user_agent =~ ~r/Firefox|FxiOS/ -> "firefox"
      user_agent =~ ~r/Chrome|CriOS/ -> "chrome"
      user_agent =~ ~r/Safari/ -> "safari"
      true -> "other"
    end
  end

  defp mobile?(user_agent), do: user_agent =~ ~r/Mobi|Android|iPhone|iPad/
end
