# EFT Buddy — session handoff

> Scratch handoff for starting a fresh session. **Not committed to any PR.** Delete when done.
> Companion file: `CACHING-NOTES.md` (deeper explainer on caching concepts).
>
> **No secrets in this file.** Credentials are referenced by name only.

Written 2026-08-03. `main` is at `860029b`, fully deployed to the VM.

---

## 1. Where things stand

Everything discussed has been merged to `main` and deployed. There are **no open PRs**.

| PR | What |
|---|---|
| #5 | Verify database TLS against Supabase's CA instead of disabling it |
| #6 | Set the app's own icons, replacing the Phoenix defaults |
| #7 | Let dev talk to a local Postgres again |
| #8 | Add an operator dashboard reachable only over an SSH tunnel |
| #9 | Batch the hideout requirements read instead of one query per station |
| #10 | Cache sync-populated reads, and poll flea prices every 10 minutes |

**The next piece of work is decided but not started** — see §7.

---

## 2. Infrastructure

### The VM

- Ubuntu 24.04, host `rcorreia01`, **192.168.59.71**, user `rcorreia`.
- **Reachable only over the VPN.** If SSH times out, check the VPN first — three TAP
  adapters and no route to `192.168.59.0/24` means the tunnel is down, not the VM.
- App lives in `/opt/eftbuddy` (a git clone of `main`).
- Docker Compose: container `eftbuddy-app-1`, image `eft-buddy:local`,
  `restart: unless-stopped`.
- Resources: **1,967 MB RAM** (~690 MB used, ~1,280 MB available), 15 GB disk (50% used).

### Access gotchas

- SSH key `~/.ssh/id_ed25519_auth` is **passphrase-protected**, and the Windows `ssh-agent`
  service is **stopped and disabled**. Plain `ssh -i` fails with `Permission denied
  (publickey)` even though the server accepts the key. Either enable ssh-agent once, or use
  an `SSH_ASKPASS` helper.
- `rcorreia` has **no passwordless sudo**, and `systemctl reboot` over SSH is blocked by
  polkit. Privileged operations need the sudo password from the user.

### Database

- **Supabase pooler**: `aws-1-eu-west-2.pooler.supabase.com:5432` (AWS London).
- Connection is **verified TLS** pinned to Supabase's private CA — see §3.
- **~76 ms round-trip per query from the VM.** This is the single most important
  performance fact in the project.

### Ports

| Port | Binding | What |
|---|---|---|
| 4000 | `0.0.0.0` | The app, fronted by nginx on the proxy host |
| 4001 | **`127.0.0.1` only** | LiveDashboard — see §5 |

---

## 3. Database TLS (PR #5) — do not undo

Supabase runs its **own PKI**. The pooler chains to `Supabase Root 2021 CA`, which is in no
OS trust store, so `:public_key.cacerts_get/0` cannot build a path to it and `verify_peer`
fails with `Fatal - Unknown CA`. That is why `DB_SSL_INSECURE=true` was originally needed —
it was not a misconfiguration and will not fix itself.

The fix is `DB_CACERTFILE`, which uses `cacertfile:` **instead of** `cacerts:` — never both.
Adding the public CAs back alongside a pinned root would let any of them vouch for the
database, which is the property pinning exists to remove.

- CA committed at `priv/certs/supabase-prod-ca-2021.crt` (a **public** certificate — public
  key only, no private material, identical for every Supabase customer).
- Baked into the image at the stable path `/app/certs/`, **not** the release's versioned
  `priv/` path, because a `version:` bump in `mix.exs` would otherwise silently break TLS.
- Verified end to end: with the pin, Erlang completes a TLS 1.3 handshake with chain and
  hostname verified; without it, `unknown_ca`.
- The leaf SAN is the wildcard `*.pooler.supabase.com`, so the
  `pkix_verify_hostname_match_fun(:https)` in the config is **load-bearing** — Erlang's
  stricter default hostname check would reject it.

`pg_stat_ssl` reports `ssl=false` even on a correctly encrypted connection. That view
reflects the pooler-to-Postgres hop **inside** Supabase, not the client-to-pooler hop. Not a
problem.

---

## 4. Deploy procedure

```sh
cd /opt/eftbuddy
git pull
docker compose build app      # old container keeps serving throughout
# any .env change goes HERE, between build and up
docker compose up -d app      # recreates from the new image; seconds of downtime
```

**Never `docker compose down` first** — the Elixir release build takes minutes and `down`
means offline for all of it. `up -d` already recreates the container when the image changed.

**`.env` changes that depend on new code must land between `build` and `up -d`.** The
container is `restart: unless-stopped`, so editing `.env` early means a crash or reboot
brings the app up against an image that does not understand the new variable.

### Verifying a deploy actually landed

Three separate states can drift: `origin/main` → local checkout → image → container.

```sh
# 1. source up to date?
git fetch origin && git rev-list --count HEAD..origin/main     # 0 = nothing to pull

# 2. container built from that source? (must ascend: commit -> image -> container)
git log -1 --format='commit  %cd' --date=format:'%Y-%m-%d %H:%M:%S'
docker image inspect eft-buddy:local --format 'image   {{.Created}}'
docker inspect eftbuddy-app-1 --format 'started {{.State.StartedAt}}'

# 3. functional proof (strongest)
docker compose exec -T app /app/bin/eft_buddy rpc \
  'IO.puts(function_exported?(EftBuddy.Hideout, :get_level_requirements_for, 1))' < /dev/null
```

**Deferred idea:** bake the git SHA into the image as a build arg and expose it on
`/health`, so verification becomes `curl .../health | jq -r .version`. Small change, makes
all of the above unnecessary.

---

## 5. Operator dashboard (PR #8)

LiveDashboard on its **own endpoint and port**, published to loopback only.

```sh
ssh -N -L 4001:127.0.0.1:4001 rcorreia@192.168.59.71
# then http://localhost:4001/dashboard
```

**Why it is safe:** compose publishes `127.0.0.1:4001:4001`, so Docker binds the host side
to loopback and nothing off the machine can route to it. The SSH tunnel's far end originates
*on* the VM, which is what satisfies that binding — so the operator's **SSH key is the
dashboard's authentication**. No password, no public route to brute-force.

Verified from a machine on the VPN: `192.168.59.71:4001` → **connection refused**, while
`192.168.59.71:4000/health` → 200 (proving the network path works and it is specifically
4001 that is unreachable). Same page over the tunnel → 200.

**Fail-closed:** `runtime.exs` only writes `:admin_dashboard` when `ADMIN_DASHBOARD_PORT` is
set, and `Application` only starts the endpoint when that key exists. Unset → the port is
never bound. It is currently **set to 4001** on the VM.

The admin router deliberately sets **no CSP** — LiveDashboard bootstraps from an inline
`<script>` and `script-src 'self'` blanks the page. Acceptable because the socket is not
reachable off-host.

---

## 6. Performance: the real numbers

### Root cause

**Every query costs ~76 ms** because the database is in AWS London and the VM is on-prem.
Locally it is a fraction of a millisecond. The VM shows **2% CPU and low RAM** — those
numbers are healthy *because* the app is idle in I/O wait. Resource graphs will never show
this problem.

### Hideout (fixed in #9 + #10) — measured on production

| | Queries | Time |
|---|---|---|
| Before | 51 | **6,935 ms** |
| After, cold cache | 5 | **1,047 ms** |
| After, warm cache | **0** | **3 ms** |

The N+1: `build_initial_modules/0` called `get_level_requirements/2` inside `Enum.map` over
26 stations. Invisible locally (~50 ms), fatal at 76 ms/query. Also hidden by
`hideout_live.ex:21` — `if connected?(socket)` means the *dead* render loads nothing, so
`curl /hideout` returned in 3 ms while the real work happened after the WebSocket connected.

### What is still slow — measured with REAL call shapes

| Tab | Main read | Queries | Time |
|---|---|---|---|
| Tasks | `list_tasks(preloads: [:trader], game_mode:)` ×2 modes + `Wiki.all_quests` | 2+2+1 | **~730 ms** |
| Ammo | `Ammo.list_rounds` | 6 | ~1,472 ms |
| Storyline | `Chapters.list_chapters` | 1 | ~761 ms |
| Events | `Events.list_events` | 2 | ~349 ms |
| Items / Flea | `list_all_items`, `list_flea_market_items` | 2–3 | ~250 ms each |

**These are not N+1s.** They are large payloads crossing a 76 ms link.

### ⚠️ Two measurement mistakes made this session — do not repeat

1. **`self()` filtering hides preloads.** Ecto runs preloads in **separate processes**. A
   telemetry counter filtered on `self() == test_pid` counts only the parent query. This
   made `list_tasks` look like "1 query" when it issues 13. **Count without a pid filter**
   when measuring a whole operation.
2. **Measure the call shape the page actually uses.** `Tasks.list_tasks()` with default
   preloads is 11 queries / 2,989 ms / 25.91 MB. The page calls
   `list_tasks(preloads: [:trader], …)` — **2 queries / 240 ms / 1.76 MB**. Measuring the
   default produced a 4× overstatement.

---

## 7. NEXT WORK — the caching plan (decided, not started)

### What already exists (PR #10)

`EftBuddy.Cache` — ETS-backed, entries dropped on the
`[:eft_buddy, :sync, :stop]` telemetry event `Sync.Reporter` emits. A 20-minute TTL is a
**backstop only**, for when that event never fires (a syncer that dies before emitting would
otherwise leave the cache stale forever, silently).

**Freshness is not traded away**: a cached read returns exactly what an uncached one would,
because both return what the last sync wrote. Skipping the cache gives fresher *reads* of
equally old data, not fresher data.

Currently cached (8 functions, all bounded): `Hideout.list_modules/0`,
`get_level_requirements_for/1`, `get_total_item_cost/2`; `Maps.list_maps/1`;
`Tasks.prereq_map/1`, `traders_with_tasks/1`; `Items.scope_counts/1`,
`flea_market_counts_by_category/1`.

Off in **test** (suite inserts fixtures and reads them back) and **dev** (local DB, would
hide writes; `CACHE_ENABLED=1` to exercise).

### Step 1 — cache the bounded list reads + warm on sync

Cache with their **real call shapes**: `Tasks.list_tasks`, `Ammo.list_rounds`,
`Armor.list_plates`, `Events.list_events`, `Chapters.list_chapters`.

**Memory cost — measured, not estimated:**

| Dataset | Size |
|---|---|
| Tasks (both modes) + wiki quests | 3.59 MB |
| Chapters | 2.42 MB |
| Ammo | 0.91 MB |
| Events | 0.17 MB |
| Armor | 0.17 MB |
| **Total** | **< 10 MB** |

Against ~1,280 MB available. Memory is **not** a constraint.

**Warming design (agreed):**
- Warm **on sync completion**, not at boot. Boot alone is the wrong hook because
  `Sync.Bootstrap` runs right after startup and would invalidate anything just warmed. Sync
  completion is also exactly when the cache was emptied — so hooking both to the same event
  keeps it permanently warm.
- Warm **asynchronously**, or a slow warm delays the endpoint accepting connections.
- Effect: the VM absorbs every cold read; users never hit one.

### Step 2 — the three UNBOUNDED functions (separate PR)

These **cannot** be cached by result. All in `lib/eft_buddy/items.ex`:

| Function | Unbounded on |
|---|---|
| `Items.list_all_items/1` | `:query` (free text), `:favorite_slugs` (per-operator), `:offset` |
| `Items.list_flea_market_items/1` | `:query`, `:favorite_slugs`, `:pmc_level`, `:offset` |
| `Items.flea_market_status_counts/1` | `:favorite_slugs`, `:pmc_level` |

- `:query` — every distinct search string is a new key; hit rate near zero.
- `:favorite_slugs` — **one entry per user**, changing whenever they star something. Turns a
  shared cache into per-user storage that grows with the audience.
- `:offset` — infinite scroll, one key per page.
- `:pmc_level` — 1–79; bounded but multiplies against all of the above.

**These three are the entire Items and Flea Market pages' main reads**, so those two tabs
stay at current speed until this is done.

**The fix** is the dataset approach: cache the underlying rows once (shared, nothing
user-specific in the key), then do search / favourites / filtering / paging **in memory**.
The VM has CPU to spare (2%). This is a real restructure — those functions currently push
all of that into SQL — and needs equality tests proving identical output.

**Recommendation:** do Step 1 first and measure it, so Step 2 is judged against a known-good
baseline.

### Flea "liveness" — settled

`PricesSync` now runs every **10 minutes** (was 15), against an upstream that refreshes
roughly every 15. Polling faster does not beat the source; it removes the
phase-misalignment penalty, bounding added lag at 10 rather than 15 minutes. Cost is 50%
more calls for a refresh that writes only changed price columns.

The user decided **not** to surface "prices are N minutes old" in the UI.

---

## 8. Outstanding / not done

1. **Rotate the Supabase `DB_PASSWORD`.** A crashed probe printed the VM's password in
   plaintext to a terminal during this session. Note **two different** Supabase passwords
   were in play — the VM's and an older one in the local `.env` — so check which is live
   before rotating. Also delete the stale `.env.bak-*` on the VM afterwards.
2. **Steps 1 and 2 of §7.**
3. **Bake the git SHA into `/health`** (§4).
4. **Local `.env` hygiene.** `TEST_DB_HOSTNAME` used to point at production Supabase;
   `config/test.exs` now **refuses a non-local test host** (`TEST_DB_ALLOW_REMOTE=true`
   opts out), and the local `.env` no longer names a test host at all.
5. **Stale-data wipe (dropped, but the approach is recorded).** `mix ecto.reset` **cannot**
   run on the VM: the runtime image has no mix/elixir/psql, and `ecto.drop` would target
   `DROP DATABASE postgres` — Supabase's own database. The correct operation is `TRUNCATE`
   of the app's tables (excluding `schema_migrations`, and `bug_reports` which is
   user-submitted and currently empty), then restart so `Bootstrap` repopulates.

---

## 9. Local development

- **PostgreSQL 18** runs as a Windows service `postgresql-x64-18`, `scram-sha-256` auth.
- Database `eft_buddy_dev`, 52 tables, 73 migrations.
- **There is no dotenv loader in this project** — Mix never reads `.env`. Variables must be
  in the shell first:

```powershell
Get-Content .env | Where-Object { $_ -match '^\s*[A-Za-z_]\w*=' } |
  ForEach-Object { $k,$v = $_ -split '=',2; Set-Item "env:$k" $v }
mix phx.server
```

- `.env` format matters: `KEY=value`, **no spaces around `=`**. It previously used
  `KEY = value`, which most loaders read as a key with a trailing space.
- Seeds are empty — data comes from the syncers hitting the live Tarkov.dev API and Fandom
  wiki on boot. A fresh local database populates itself (items ~5,200, tasks ~1,000).
- Dev DB **must not** use TLS: a stock local Postgres does not serve it, and Postgrex fails
  outright rather than downgrading. `config/dev.exs` skips verification for
  `localhost`/`127.0.0.1`/`::1` (PR #7). `DB_SSL=true` forces it back on.
- Dev-only LiveDashboard is at `/dev/dashboard` (via the `:dev_routes` compile guard). The
  tunnel setup only applies to production.

---

## 10. Conventions and gotchas

- **Commits and PRs are authored as the user.** No `Co-Authored-By: Claude` trailer, no
  "Generated with Claude Code" footer. The user asked for this explicitly.
- **`docker compose exec -T` reads stdin.** Inside a heredoc-driven ssh script it swallows
  the rest of the script — always append `< /dev/null`.
- **Never probe the Repo with `/app/bin/eft_buddy eval 'EftBuddy.Repo.start_link()'`.**
  `db_connection` is not started under `eval`, so it fails at `DBConnection.Watcher`, and
  the Ecto crash dump prints the **database password in plaintext**. Use the image's own
  `openssl` for TLS checks — it needs no credentials.
- **`git pull` on the VM is blocked by untracked files the repo now tracks.** This bit us
  with `docker-compose.yml`. Check `git status --porcelain | grep '^??'` before pulling.
- The production route surface is **17 routes**, no admin surface. `/dev/*` and `/dashboard`
  all return 404 in production — verified by enumerating
  `EftBuddyWeb.Router.__routes__()` on the running release.
- CI builds **amd64 and arm64**. The Dockerfile's Debian pin is a **date** and not a free
  choice: `bookworm-20250610` is published for arm64 only and could not build on the amd64
  VM at all. `bookworm-20260610` publishes both. Verify with
  `docker manifest inspect … | grep architecture` before bumping.

---

## 11. Scratch files to delete

- `CACHING-NOTES.md` — caching concepts explainer.
- `HANDOFF.md` — this file.

Both are untracked and in the repo root. They are **not** gitignored, so a `git add -A`
would pick them up. They are excluded from the Docker image (`.dockerignore` drops root
`*.md` except `README.md`).
