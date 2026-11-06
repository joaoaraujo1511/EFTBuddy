# How eftbuddy.app runs

This describes the project's own instance. It's here for reference: running your
own copy is allowed by the licence, but isn't supported.

## Setup

Three containers in one Compose file, behind a Cloudflare Tunnel, so the host opens
no inbound ports:

```
Browser → Cloudflare → cloudflared → app :4000 → db :5432
```

## Configuration

All configuration is read at runtime, so one image runs anywhere. `.env.example`
lists the production variables. Three are easy to get wrong:

- **`PHX_HOST`** must be a bare hostname (no scheme, port or slash). If it's wrong,
  pages still load but every live connection is rejected.
- **`SECRET_KEY_BASE`**: generate it with `mix phx.gen.secret`.
- **`DB_PASSWORD`** is kept separate from `DATABASE_URL` so it never shows up in
  logs.

`TUNNEL_TOKEN` is required for the `cloudflared` service. Treat it like a private
key.

## Deploying

```sh
git pull
GIT_SHA=$(git rev-parse --short HEAD) docker compose build app
docker compose run --rm migrate < /dev/null
docker compose up -d < /dev/null
```

- Build **before** `up -d`, and don't run `down` first. The old container keeps
  serving while the new image builds.
- Migrations run as their own one-shot container, not on app start.
- Keep `< /dev/null` when scripting this over SSH. Compose reads stdin and will
  otherwise swallow the rest of your script.

## Health

| Endpoint | Meaning |
|---|---|
| `/health` | The app and database are up. `version` is the deployed commit |
| `/health/sync` | Every data feed is fresh. Returns 503 when one is stale, failing or blocked by a safety guard |

Stale game data still renders fine, so `/health/sync` is the only place it shows.

More detail is available on a separate admin endpoint, off unless
`ADMIN_DASHBOARD_PORT` is set and published to loopback only.
