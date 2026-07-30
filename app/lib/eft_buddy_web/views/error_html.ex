defmodule EftBuddyWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error responses for the public site.

  Instead of Phoenix's default plain-text status message ("Not Found",
  "Internal Server Error", ...) we serve a themed OPERATOR-HUD error page so
  a stray 404 / 500 / 503 still looks like part of the app.

  The page is intentionally **self-contained**: all styling is inlined in a
  `<style>` block and there is no dependency on `app.css`, the LiveView
  socket, or the root layout. That matters because error pages are exactly
  the moments when those things may be unavailable - a 500 can be raised
  *because* a LiveView crashed, and we still want a clean page to come back.
  Links use plain paths (not verified routes) for the same robustness.

  `config/config.exs` wires this module up via `render_errors` with
  `layout: false`, so whatever `render/2` returns is the full response body.
  """
  use EftBuddyWeb, :html

  # Friendly, Tarkov-flavoured copy for the status codes we actually expect
  # to serve. Anything else is handled by the generic fallback clause below,
  # so every error - known or not - still gets a styled page.

  def render("400.html", assigns),
    do:
      page(
        assigns,
        400,
        "Bad Transmission",
        "The request couldn't be parsed. Double-check the link and try again."
      )

  def render("403.html", assigns),
    do:
      page(
        assigns,
        403,
        "Access Denied",
        "You don't have clearance for this sector."
      )

  def render("404.html", assigns),
    do:
      page(
        assigns,
        404,
        "Signal Lost",
        "This location isn't on the map. The page you're looking for has been moved, extracted, or never existed."
      )

  def render("429.html", assigns),
    do:
      page(
        assigns,
        429,
        "Slow Down, Operator",
        "Too many requests in a short window. Hold position for a moment, then try again."
      )

  def render("500.html", assigns),
    do:
      page(
        assigns,
        500,
        "System Fault",
        "Something broke on our end. The incident has been logged - try again shortly."
      )

  def render("503.html", assigns),
    do:
      page(
        assigns,
        503,
        "Stash Offline",
        "The service is temporarily unavailable - likely maintenance or heavy load. Try again in a moment."
      )

  # Generic fallback for any other status code Phoenix hands us. We keep the
  # real status code in the page and use Phoenix's status message as the body.
  def render(template, assigns) do
    page(
      assigns,
      status_code(template),
      "Operation Failed",
      Phoenix.Controller.status_message_from_template(template)
    )
  end

  # "404.html" -> 404, "418.html" -> 418, anything unparsable -> 500.
  defp status_code(template) do
    case Integer.parse(template) do
      {code, _rest} -> code
      :error -> 500
    end
  end

  # The full standalone document. Inline `<style>` keeps it dependency-free;
  # the muted gunmetal/amber palette mirrors the OPERATOR HUD design system.
  defp page(assigns, status, title, message) do
    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:title, title)
      |> assign(:message, message)
      |> assign(:page_title, "#{status} · #{title}")

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@page_title} · EFT Buddy</title>
        <style>
          /* Self-hosted fonts, mirroring app.css so the standalone error page
             matches the app's type instead of falling back to system fonts.
             (JetBrains Mono is intentionally system-only here, same as app.css.) */
          @font-face { font-family: "Oswald"; font-style: normal; font-weight: 500; font-display: swap; src: url("/fonts/oswald-500.woff2") format("woff2"); }
          @font-face { font-family: "Oswald"; font-style: normal; font-weight: 600; font-display: swap; src: url("/fonts/oswald-600.woff2") format("woff2"); }
          @font-face { font-family: "Oswald"; font-style: normal; font-weight: 700; font-display: swap; src: url("/fonts/oswald-700.woff2") format("woff2"); }
          @font-face { font-family: "Inter"; font-style: normal; font-weight: 400; font-display: swap; src: url("/fonts/inter-400.woff2") format("woff2"); }
          @font-face { font-family: "Inter"; font-style: normal; font-weight: 700; font-display: swap; src: url("/fonts/inter-700.woff2") format("woff2"); }
          :root {
            --ink-950: #121212;
            --ink-900: #181818;
            --panel: #1e1e1e;
            --line: #2c2c2c;
            --line-strong: #3b3b3b;
            --fog-100: #e7e4d6;
            --fog-300: #bcb9a6;
            --fog-500: #8f8c78;
            --fog-600: #82806d;
            --amber: #9a8866;
            --amber-bright: #c0ac86;
          }
          * { box-sizing: border-box; }
          html, body { height: 100%; margin: 0; }
          body {
            background-color: var(--ink-950);
            background-image:
              linear-gradient(180deg, rgba(154,136,102,0.05) 0%, rgba(18,18,18,0) 38%),
              linear-gradient(rgba(255,255,255,0.028) 1px, transparent 1px),
              linear-gradient(90deg, rgba(255,255,255,0.028) 1px, transparent 1px);
            background-size: 100% 100%, 44px 44px, 44px 44px;
            color: var(--fog-300);
            font-family: "Inter", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 1.5rem;
            -webkit-font-smoothing: antialiased;
          }
          .panel {
            width: 100%;
            max-width: 32rem;
            background:
              linear-gradient(180deg, rgba(255,255,255,0.018), rgba(0,0,0,0)),
              var(--panel);
            border: 1px solid var(--line);
            clip-path: polygon(14px 0, 100% 0, 100% calc(100% - 14px), calc(100% - 14px) 100%, 0 100%, 0 14px);
            padding: 2.5rem 2rem;
            text-align: center;
          }
          .eyebrow {
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            font-family: "Oswald", "Arial Narrow", system-ui, sans-serif;
            text-transform: uppercase;
            letter-spacing: 0.24em;
            font-size: 0.625rem;
            color: var(--amber);
            margin-bottom: 1.25rem;
          }
          .tick {
            width: 8px; height: 8px;
            background: var(--amber);
            transform: rotate(45deg);
            display: inline-block;
          }
          .code {
            font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
            font-size: 5rem;
            line-height: 1;
            color: var(--amber);
            font-variant-numeric: tabular-nums;
            letter-spacing: -0.02em;
          }
          .title {
            font-family: "Oswald", "Arial Narrow", system-ui, sans-serif;
            text-transform: uppercase;
            letter-spacing: 0.02em;
            font-size: 1.75rem;
            font-weight: 700;
            color: var(--fog-100);
            margin: 0.75rem 0 0;
          }
          .message {
            font-size: 0.9rem;
            line-height: 1.6;
            color: var(--fog-500);
            margin: 0.75rem auto 0;
            max-width: 26rem;
          }
          .rule {
            height: 1px;
            margin: 1.75rem 0;
            background: linear-gradient(90deg, var(--amber), rgba(154,136,102,0));
          }
          .actions {
            display: flex;
            flex-wrap: wrap;
            gap: 0.75rem;
            justify-content: center;
          }
          .btn {
            font-family: "Oswald", "Arial Narrow", system-ui, sans-serif;
            text-transform: uppercase;
            letter-spacing: 0.12em;
            font-size: 0.75rem;
            text-decoration: none;
            padding: 0.7rem 1.25rem;
            border: 1px solid var(--line-strong);
            color: var(--fog-300);
            transition: color .15s, border-color .15s, background-color .15s;
          }
          .btn:hover { color: var(--amber); border-color: var(--amber); }
          .btn-solid {
            background: var(--amber);
            color: var(--ink-950);
            border-color: var(--amber);
            font-weight: 700;
          }
          .btn-solid:hover {
            background: var(--amber-bright);
            border-color: var(--amber-bright);
            color: var(--ink-950);
          }
          .brand {
            font-family: "Oswald", "Arial Narrow", system-ui, sans-serif;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            font-size: 0.625rem;
            color: var(--fog-600);
            margin-top: 1.75rem;
          }
          .brand b { color: var(--fog-300); font-weight: 700; }
        </style>
      </head>
      <body>
        <main class="panel">
          <div class="eyebrow"><span class="tick"></span> Operator HUD · Fault</div>
          <div class="code">{@status}</div>
          <h1 class="title">{@title}</h1>
          <p class="message">{@message}</p>
          <div class="rule"></div>
          <div class="actions">
            <a class="btn btn-solid" href="/">Return to base</a>
            <a class="btn" href="/report-bug">Report a bug</a>
          </div>
          <div class="brand">EFT<b>//</b>BUDDY · Tarkov Companion</div>
        </main>
      </body>
    </html>
    """
  end
end
