# EFT Buddy

A companion web app for Escape from Tarkov — items, ammo, tasks, maps, the flea
market, the hideout and the storyline, kept current from public data sources.

Phoenix LiveView front to back: every page is a live view, there are no accounts
and no login, and the whole catalogue is rebuilt from upstream feeds rather than
hand-maintained.

> **Status.** This README is the start of a fuller one. It covers how the app is
> built, run and deployed; it does not yet cover the domain model, the sync
> feeds in detail, or contribution guidelines.

## What it is made of

| | |
|---|---|
| Language / runtime | Elixir on OTP |
| Web | Phoenix + LiveView, served by Bandit |
| Database | PostgreSQL 17, via Ecto |
| Assets | esbuild + Tailwind, digested and gzipped at build time |
| Packaging | A Mix-free OTP release in a multi-stage Docker image |
| Serving | Cloudflare Tunnel in front of the app container |

The image builds unmodified on `amd64` and `arm64`, and CI produces both.

## Running it locally

Requirements: Elixir and Erlang/OTP as pinned in `.tool-versions`, plus a local
PostgreSQL server.

```sh
mix setup          # deps, database, assets
mix phx.server     # http://localhost:4000
```

`mix setup` runs `deps.get`, creates and migrates the database, and installs and
builds the front-end toolchain.

### Tests

```sh
mix test
```

The suite needs its own database and reads `TEST_DB_*` environment variables —
deliberately **not** the `DB_*` names development uses, so that pointing dev at a
remote database can never cause the suite to create, truncate or drop anything
there. `config/test.exs` explains the reasoning; it is worth reading once before
setting `TEST_DB_HOSTNAME` to anything other than `localhost`.

### Before pushing

```sh
mix precommit
```

Dependency and advisory audits, a warnings-as-errors compile, unused-dependency
check, formatter, Sobelow, and the test suite. The two audits run first, on
purpose — `hex.audit` becomes unresolvable once `mix compile` has run in the same
OS process, and it fails faster on a vulnerable dependency than a full compile
does.

## Configuration

Everything is read at runtime, not compile time, so one image runs in any
environment. `.env.example` is the reference: every variable is documented there,
including which ones make the release refuse to boot when unset. Copy it and fill
it in.

```sh
cp .env.example .env
```

Three that are easy to get wrong:

- **`PHX_HOST`** must be a **bare hostname** — no scheme, port, path or trailing
  slash. It is compared verbatim against the `Origin` header of every LiveView
  socket. Get it wrong and pages render, `/health` still returns 200, and every
  socket is silently rejected. `config/runtime.exs` rejects malformed values at
  boot rather than letting that happen.
- **`SECRET_KEY_BASE`** — generate with `mix phx.gen.secret`.
- **`DB_PASSWORD`** is deliberately separate from `DATABASE_URL`, so the password
  stays out of logs, crash dumps and anywhere the URL gets echoed.

`.env` is both gitignored and dockerignored — two separate mechanisms that have
to be maintained separately.

## Deployment

The app is self-hosted on a single small ARM64 machine — a Raspberry Pi 5 running
Raspberry Pi OS — with three containers managed by one Compose file:

```
Browser → Cloudflare edge (TLS, caching, DDoS, WAF)
            ↓  tunnel, outbound-only
        cloudflared  ──►  app :4000  ──►  db :5432
                          (compose network)
```

Three properties of that shape are deliberate:

- **No inbound ports.** `cloudflared` dials out to Cloudflare and holds the
  connection open. The host needs no port forwarding, no static address, and
  public DNS points at Cloudflare rather than at the origin.
- **The database publishes no host port at all.** It is reachable only as `db` on
  the Compose network. For a `psql` prompt, go through the container.
- **Rootless Docker.** The daemon runs as an unprivileged user, so a container
  breakout lands as that user rather than as root. This is why the database uses
  a named volume rather than a bind mount, and why nothing here publishes a port
  below 1024.

### Deploying

```sh
git pull
GIT_SHA=$(git rev-parse --short HEAD) docker compose build app
docker compose run --rm migrate
docker compose up -d
```

Build **before** `up -d`, and never `down` first: the release build takes minutes
and `down` means offline for all of them, while `up -d` already recreates a
container whose image changed.

Migrations run as a separate one-shot container, deliberately outside the app's
startup path. Migrating on boot makes every restart race itself once there is
more than one instance, and turns a failed migration into a crash-loop rather
than a command that reports an error.

> When scripting a deploy over SSH by piping into `bash -s`, append `< /dev/null`
> to every `docker compose run` and `exec`. Compose reads stdin, and stdin is the
> rest of your script — it will silently swallow the remaining commands, and the
> deploy will look like it succeeded.

### Verifying a deploy

```sh
curl -s http://127.0.0.1:4000/health
```

`GIT_SHA` is baked into the image and reported as `version`, so confirming a
deploy landed is one request rather than comparing a commit date, an image date
and a container start time by eye. **Check the reported SHA, not the exit code.**

`/health/sync` reports every upstream feed's state and age, which is the reliable
signal for whether the catalogue is current.

### Logs

```sh
docker compose logs -f app
docker compose logs -f db     # queries slower than 1s
docker compose logs -f cloudflared
```

Container logs are capped at 10 MB × 3 per container, so history does not grow
without bound on flash storage.

## Operational notes

**The operator dashboard** (LiveDashboard) runs on its own endpoint and port, and
starts only when `ADMIN_DASHBOARD_PORT` is set. Compose publishes it to
**loopback only**. That binding is the entire access control, and it is not
cosmetic: the page can read ETS, list processes and kill them. Reach it by
forwarding the port over SSH, so the operator's SSH key is what guards it.

**Storage.** The Postgres settings in `docker-compose.yml` are tuned for 8 GB of
RAM, four cores, and a data directory on flash. The WAL settings in particular
trade latency for fewer, larger writes, because flash wears out by write volume.
Revisit them if the data directory ever moves to an SSD.

**Backups.** Only one table is not re-derivable from upstream sources; everything
else the sync feeds would refill on their own. A nightly logical dump with
retention covers it, and a backup that has never been restored is not a backup —
test the restore into a scratch database.

## Repository layout

| Path | |
|---|---|
| `lib/eft_buddy/` | domain logic, sync feeds, caching |
| `lib/eft_buddy_web/` | endpoint, router, LiveViews, components |
| `config/` | `config.exs`, per-env files, and `runtime.exs` for release config |
| `priv/repo/migrations/` | schema history |
| `test/` | ExUnit suite |
| `rel/overlays/bin/` | release entrypoints (`server`, `migrate`) |

`AGENTS.md` holds the Elixir, Phoenix and LiveView conventions this codebase
follows. Comments throughout the tree tend to explain **why** a thing is the way
it is, frequently because the alternative was tried and broke something — they
are worth reading before changing the code they sit above.

Host-specific operational detail (addresses, identifiers, and the exact state of
the deployed machine) is kept out of this repository by design.

## Licence

See `LICENSE` and `NOTICE`.
