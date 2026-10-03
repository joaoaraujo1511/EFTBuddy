# EFT Buddy

An unofficial companion web app for *Escape from Tarkov*: quests, items, the flea
market, the hideout, ammo, maps, events and the storyline, kept current from
public data sources.

No accounts and no login. Your progress lives in your own browser.

> EFT Buddy is a non-commercial fan project and is **not affiliated with or
> endorsed by Battlestate Games**. See [`NOTICE`](NOTICE).

## Features

| Page | What it does |
|---|---|
| **Tasks** | Quest tracker: mark quests complete, watchlist, filters, prerequisites, Kappa/Lightkeeper progress, wiki walkthroughs |
| **Items** | Searchable item catalogue with where each item is used (quests, hideout, barters, crafts) |
| **Flea Market** | Current flea prices with a short price history |
| **Hideout** | Station levels and what each upgrade needs |
| **Ammo** | Ballistics table and armour-plate penetration |
| **Maps** | Interactive maps with extracts, bosses and quest markers |
| **Events** | Seasonal events and their quests |
| **Storyline** | Story chapters, including a page per ending |

PVP and PVE are tracked separately. Use **Backup** in the top bar to export,
import or reset your progress.

## Where the data comes from

- Game data from the [tarkov.dev](https://tarkov.dev) API.
- Walkthroughs, events and story chapters from the
  [Escape from Tarkov Wiki](https://escapefromtarkov.fandom.com), under
  CC BY-NC-SA. Each page credits its source.

Background jobs re-sync everything on a schedule, so the catalogue is never
edited by hand.

## Run it locally

You need Erlang/OTP and Elixir (versions in `.tool-versions`) and PostgreSQL.

```sh
cp .env.example .env     # fill it in, then export it into your shell
mix setup                # dependencies, database, assets
mix phx.server           # http://localhost:$PORT
```

There is no dotenv loader, so export the variables yourself. `PORT` is required.

### Tests

```sh
mix test
```

The suite uses its own `TEST_DB_*` variables, never the `DB_*` ones, and refuses
to run against a non-local database. If your local Postgres isn't the stock
`postgres`/`postgres`, export `TEST_DB_PASSWORD` first.

### Before you push

```sh
mix precommit
```

This runs the dependency audits, a warnings-as-errors compile, the formatter
check, Sobelow and the test suite.

## Configuration

All configuration is read at runtime, so one image runs anywhere.
`.env.example` lists the variables. Three are easy to get wrong:

- **`PHX_HOST`** must be a bare hostname (no scheme, port or slash). If it's
  wrong, pages still load but every live connection is rejected.
- **`SECRET_KEY_BASE`**: generate it with `mix phx.gen.secret`.
- **`DB_PASSWORD`** is kept separate from `DATABASE_URL` so it never shows up
  in logs.

## Deploying

The production setup is three containers in one Compose file, behind a
Cloudflare Tunnel, so the host opens no inbound ports:

```
Browser → Cloudflare → cloudflared → app :4000 → db :5432
```

You need `TUNNEL_TOKEN` in `.env` for the `cloudflared` service.

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

### Is it healthy?

| Endpoint | Meaning |
|---|---|
| `/health` | The app and database are up. `version` is the deployed commit, so check it after a deploy |
| `/health/sync` | Every data feed is fresh. Returns 503 when any feed is stale, failing or blocked by a safety guard |

Point an uptime monitor at `/health/sync`. Stale game data still renders fine,
so this is the only place it shows.

## Project layout

| Path | Contents |
|---|---|
| `lib/eft_buddy/` | Domain logic, data feeds (`*/sync.ex`), caching |
| `lib/eft_buddy_web/` | Router, LiveViews, components |
| `assets/` | JavaScript and CSS |
| `priv/repo/migrations/` | Database schema |
| `test/` | Test suite |
| `config/runtime.exs` | All runtime configuration |

Comments in the code usually explain *why* something is done a certain way,
often because the obvious alternative broke in production. Read them before
changing the code.

## Licence

[GNU AGPL v3](LICENSE). Game names, images and other material belong to their
owners; see [`NOTICE`](NOTICE) for attribution and third-party terms.
