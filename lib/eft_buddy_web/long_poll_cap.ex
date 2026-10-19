defmodule EftBuddyWeb.LongPollCap do
  @moduledoc """
  Caps what a client can POST to the LiveView long-poll transport at the same
  size the WebSocket transport allows per frame (audit M27).

  `max_frame_size` bounds a single WebSocket frame, but long-poll has no such
  option: `Phoenix.Transports.LongPoll` reads each request body with Plug's
  default limit, about 8 MB, holding up to 100 messages. On the Pi most clients
  end up on long-poll (a slow WebSocket upgrade through the tunnel trips the
  client's fallback), so the cap the endpoint's comment relies on did not
  apply to most connections.

  It cannot be an ordinary plug. `use Phoenix.Endpoint` registers socket
  dispatch as the first plug, so every plug declared in the endpoint runs after
  the transport. Instead this wraps the endpoint's finished `call/2` from a
  `@before_compile` hook; hooks run in registration order, so it has to be
  registered after `use Phoenix.Endpoint`:

      use Phoenix.Endpoint, otp_app: :eft_buddy
      @before_compile EftBuddyWeb.LongPollCap

  A POST without a `content-length` header is refused too: browsers always send
  one for the string bodies phoenix.js posts, and a chunked body could not be
  measured without consuming it.
  """

  import Plug.Conn

  @path ["live", "longpoll"]

  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(%Plug.Conn{method: "POST", path_info: unquote(@path)} = conn, opts) do
        case EftBuddyWeb.LongPollCap.check(conn, max_frame_size()) do
          :ok -> super(conn, opts)
          {:reject, status} -> EftBuddyWeb.LongPollCap.reject(conn, status)
        end
      end

      def call(conn, opts), do: super(conn, opts)
    end
  end

  @doc false
  # `:ok`, or the status to refuse the request with.
  @spec check(Plug.Conn.t(), pos_integer()) :: :ok | {:reject, 411 | 413}
  def check(conn, limit) do
    case get_req_header(conn, "content-length") do
      [length] ->
        case Integer.parse(length) do
          {n, ""} when n <= limit -> :ok
          {_n, ""} -> {:reject, 413}
          _ -> {:reject, 411}
        end

      _ ->
        {:reject, 411}
    end
  end

  @doc false
  def reject(conn, status), do: conn |> send_resp(status, "") |> halt()
end
