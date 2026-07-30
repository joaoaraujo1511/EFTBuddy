defmodule EftBuddyWeb.SessionController do
  @moduledoc """
  Hard reset of the operator's server-side state, for the "Reset progress" and
  "Import from file" backup actions.

  ## Why this is a plain HTTP request

  Both actions rewrite this browser's durable storage (the `eft_prefs` cookie
  and the `localStorage` progress blob) and then reload. Because the server is
  authoritative for live operator state, it must stop serving what it currently
  holds - otherwise the reload is handed the pre-reset values and the action
  looks like it did nothing.

  Doing that over the LiveView socket is unreliable: the socket may be down or
  reconnecting (which is precisely why the backup actions are otherwise pure
  client operations), and a push issued immediately before `location.reload()`
  can be lost with the dying LiveView. A normal navigation has no such race -
  the reset is simply part of the request that loads the next page.

  ## Why it is a POST

  It is routed as `post/4`, submitted by a hidden form in the `Backup` hook
  (`assets/js/app.js`, `reloadViaServerReset`). This is a security boundary, not
  a REST preference. The action destroys progress and rotates the operator token,
  and `OperatorSessions.reset/1` broadcasts to the operator's *other* open tabs,
  emptying their `:client_state`; their next progress write then pushes that empty
  blob over `localStorage`, which is the only durable copy a player has. As a GET
  the route was reachable by a cross-site top-level navigation - `same_site:
  "Lax"` still sends the session cookie on those - so one posted link could wipe a
  visitor's tracker. `:protect_from_forgery` in the `:browser` pipeline only
  validates non-idempotent methods, so POST is what brings this under CSRF
  protection. Do not turn it back into a GET.

  ## What it does

    1. Resets the *current* session, which broadcasts to the operator's other
       open tabs so they converge instead of sitting on stale values.
    2. **Rotates** `operator_token`, so the reloading tab is handed a brand-new
       session that cold-seeds from the freshly written cookie. This is what
       makes *import* work: a session that already exists ignores seed prefs by
       design, so without rotation the imported level/karma/mode/faction would
       be discarded in favour of the live session's values.

  The old session is left to age out on its idle timeout, still serving any
  other tab attached to it until they reload.
  """
  use EftBuddyWeb, :controller

  alias EftBuddy.OperatorSessions
  alias EftBuddyWeb.Plugs.OperatorSession, as: SessionPlug

  @doc "Reset server-side operator state, rotate the token, and return to the app."
  def reset(conn, params) do
    conn
    |> get_session(SessionPlug.token_key())
    |> OperatorSessions.reset()

    conn
    # A cached response would silently skip the reset entirely, and skip the
    # token rotation that makes import work. Forbid storing it.
    |> put_resp_header("cache-control", "no-store, max-age=0")
    |> put_session(SessionPlug.token_key(), SessionPlug.generate_token())
    |> redirect(to: safe_return_to(params))
  end

  # Only ever bounce back to an in-app path.
  #
  # A genuine ALLOW-LIST, not a pair of prefix checks. "starts with `/` but not
  # `//`" looks equivalent and is not: `/\evil.example` passes it, and
  # `Phoenix.Controller.redirect/2` then *raises* on the backslash
  # (`@invalid_local_url_chars` covers `\`, `/%09` and `/\t`), turning a
  # user-supplied string into a 500. Anything outside this pattern falls through
  # to `/tasks` instead of reaching `redirect/2`.
  #
  # Deliberately narrow: every path this app can return to is a slug route with
  # at most a simple query string, so unreserved characters plus `?`, `=` and `&`
  # cover them all. Widening it means re-checking against `redirect/2`'s own
  # rejects.
  @return_to_pattern ~r{\A/[A-Za-z0-9\-._~/]*(\?[A-Za-z0-9\-._~/=&%]*)?\z}

  defp safe_return_to(%{"return_to" => path}) when is_binary(path) do
    if not String.starts_with?(path, "//") and Regex.match?(@return_to_pattern, path),
      do: path,
      else: "/tasks"
  end

  defp safe_return_to(_params), do: "/tasks"
end
