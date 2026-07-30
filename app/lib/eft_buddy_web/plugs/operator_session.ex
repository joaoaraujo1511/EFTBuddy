defmodule EftBuddyWeb.Plugs.OperatorSession do
  @moduledoc """
  Establishes the two things a LiveView mount needs to resolve the operator's
  live state:

    1. **`operator_token`** - a random, opaque id stored in the *signed* session
       cookie. It identifies this browser's `EftBuddy.OperatorSession` process.
       Because it lives in the session, it is frozen into the LiveView socket at
       connect time and therefore travels with every subsequent live navigation -
       which is exactly the property the operator state needs and the raw
       `eft_prefs` cookie lacks.

       The token is meaningless on its own: it is not a credential and grants
       nothing but access to this browser's own ephemeral UI state. It is signed
       (session cookie) purely so it can't be swapped to another browser's.

    2. **`eft_prefs`** - the browser-written prefs cookie, decoded into the
       session so a *brand new* session can be cold-seeded from it (and so the
       very first, static render is already correct before any socket exists).

  ## Why the prefs cookie is still read here

  `EftBuddy.OperatorSession` is authoritative only while it is alive. On a cold
  boot - first ever visit, or the first request after a deploy - there is no
  session, and this cookie is the only record of the operator's prefs. It is
  therefore a *seed*, not a live source: `EftBuddy.OperatorSessions.snapshot/2`
  ignores it entirely once a session exists.

  The cookie is plain (JS-readable/writable) rather than part of the signed
  session, because the browser has to be able to write it without a round-trip.
  Every value is re-validated and clamped by `EftBuddy.Operator`, so a
  hand-edited cookie can at worst set legal UI state for its own browser. The
  size cap stops a hostile cookie bloating the session.

  Deleting the cookie (the "Reset progress" action) drops the bridged copy from
  the session too, so a reset can't be undone by stale session data.
  """

  @behaviour Plug

  import Plug.Conn

  # Generous for a handful of small UI prefs; small enough that a crafted
  # cookie can't bloat the session or the connect payload.
  @max_prefs_bytes 1024

  @token_bytes 16

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> fetch_cookies()
    |> put_operator_token()
    |> bridge_client_prefs()
  end

  @doc """
  The session key holding the operator token.

  Exposed so LiveView hooks and tests read the same key instead of repeating
  the string literal.
  """
  def token_key, do: "operator_token"

  @doc "The session key holding the bridged `eft_prefs` cookie payload."
  def prefs_key, do: "eft_prefs"

  # Mint once and keep it stable for the browser's session. Reusing the
  # existing token across requests is what lets a full page reload rejoin the
  # session process it already had (progress intact) instead of re-hydrating.
  defp put_operator_token(conn) do
    case get_session(conn, token_key()) do
      token when is_binary(token) and token != "" ->
        conn

      _ ->
        put_session(conn, token_key(), generate_token())
    end
  end

  @doc """
  Mint a fresh operator token.

  Public so `EftBuddyWeb.SessionController` can *rotate* it on a reset/import,
  which is what hands the reloading tab a clean session that cold-seeds from the
  newly written cookie.
  """
  def generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  # The `eft_prefs` cookie is the single durable source for prefs: when it is
  # absent or unreadable we DROP any previously bridged copy rather than
  # leaving stale values behind, so clearing it client-side really does reset.
  defp bridge_client_prefs(conn) do
    case decode_prefs(conn.cookies[prefs_key()]) do
      nil -> delete_session(conn, prefs_key())
      prefs -> put_session(conn, prefs_key(), prefs)
    end
  end

  defp decode_prefs(raw) when is_binary(raw) and byte_size(raw) <= @max_prefs_bytes do
    # Written by JS as `encodeURIComponent(JSON.stringify(...))`, so the value
    # Plug hands us is still URL-encoded (e.g. `%7B%22pmc_level%22%3A5%7D`).
    # A malformed or hand-tampered value degrades to defaults.
    with decoded when is_binary(decoded) <- safe_url_decode(raw),
         {:ok, prefs} when is_map(prefs) <- Jason.decode(decoded) do
      prefs
    else
      _ -> nil
    end
  end

  defp decode_prefs(_raw), do: nil

  defp safe_url_decode(raw) do
    URI.decode(raw)
  rescue
    ArgumentError -> nil
  end
end
