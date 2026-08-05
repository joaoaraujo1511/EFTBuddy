# EFT Buddy — caching batch: test report

> Scratch handoff, written 2026-08-04 after deploying the caching batch and
> testing it against the hosted database. Companions: `HANDOFF.md` (infra,
> TLS, deploy), `CACHING-NOTES.md` (caching concepts), `NEXT-STEPS.md`
> (dataset-layer design decisions).
>
> **No secrets in this file.** Credentials referenced by name only.
>
> Untracked and NOT gitignored — a `git add -A` would pick it up. Excluded from
> the Docker image (`.dockerignore` drops root `*.md` except `README.md`).

---

## 1. Status in one paragraph

Seven PRs merged to `main` (`b974e43`), deployed to the VM, and verified against
the real hosted database. The read cache is live and correct. The Items/Flea
in-memory dataset layer is built, proven equal to SQL on real data, and shipped
**switched off** behind `ITEM_DATASET=1`. The database was wiped and rebuilt
cleanly, which fixed a long-standing barter duplication. **One real flaw remains
open and unfixed — see §2.** It is the first thing the next session should do.

---

## 2. OPEN ISSUE — the TTL evicts entries that warming never restores

**This is a design flaw in the shipped code, not a data problem.** Nothing else
in this document matters as much.

### Evidence, measured on the VM after a full clean rebuild

```
registered warm specs : 19
live cache entries    :  5
cumulative hit rate   : 25.6%

{Ammo, :availability}                        age  31s   ttl left 1168s
{Ammo, :ballistics}                          age  32s   ttl left 1167s
{Items, :flea_counts_by_category, :pve}      age  32s   ttl left 1167s
{Items, :flea_counts_by_category, :pvp}      age  32s   ttl left 1167s
{Wiki, :all_quests}                          age 123s   ttl left 1076s
```

Everything else — hideout modules, maps, tasks list (×2 modes), prereq_map (×2),
traders, scope counts (×2), armor plates, events, chapters, the tasks index — is
**gone**.

### Why

Two mechanisms that are each individually reasonable interact badly:

- Warming fires **on sync completion** (`EftBuddy.Cache.Warmer`)
- The TTL sweep drops entries after **20 minutes** (`EftBuddy.Cache`)

Most feeds run every **6–24 hours**. So an entry is warmed at sync time, expires
20 minutes later, is swept — and nothing re-warms it until the next sync, hours
away. The first visitor after that pays the full cold read, which is precisely
what warming was built to prevent.

The five survivors are exactly the entries owned by `PricesSync`, the only feed
whose cadence (10 min) is **shorter** than the TTL (20 min). That is the whole
explanation, and it is why the hit rate sits at 25.6%.

### The fix

Tick the warmer on a timer shorter than the TTL and re-run **all** specs. It is
self-limiting: a spec whose entry is still live costs one ETS lookup, because
`Cache.fetch/4` hits and returns without querying. Only expired entries actually
rebuild. So it is nearly free when warm and repairs the cache when not — and it
needs no mapping from spec to cache key.

- ~15 lines in `lib/eft_buddy/cache/warmer.ex`
- Derive the interval from the TTL (e.g. `div(@default_ttl_ms, 4)`) so the two
  cannot drift apart
- Keeps the TTL as a genuine staleness backstop while restoring warmth

**Do not simply raise the TTL** — that weakens the backstop that exists for
"the invalidation signal never arrived", which is the silent failure the whole
design is shaped around.

---

## 3. What was merged

`origin/main` = **`b974e43`**. All seven landed and are deployed.

| PR | Branch | What |
|---|---|---|
| #11 | `chore/build-sha-health` | `GIT_SHA` build arg → `/health` `version` |
| — | `perf/cache-observability-warming` | Warmer on its own telemetry handler, hit/miss/age metrics, LiveDashboard Cache page, `/health/sync` cache block, `CACHE_ENABLED` kill switch |
| — | `perf/cache-tier1-list-reads` | Tasks/Ammo/Armor/Events/Chapters/Wiki list reads; ammo split by lifetime; explicit source map |
| — | `perf/cache-tier1-detail-reads` | Item/task/chapter detail panels, category counts, flea unlock level; cache entry ceiling + expiry sweep |
| — | `perf/item-dataset-layer` | In-memory catalogue + price layer + order indexes + scope sets, with row-for-row equality tests |
| #16 | `perf/items-flea-from-memory` | Items/Flea dispatch to the dataset, SQL as fallback |
| #17 | `perf/dataset-filter-projection` | Filter on a projection, not full structs; dev safe to point at production |

**GitHub housekeeping wart:** PRs were opened stacked (each based on the one
below). Merging with `--delete-branch` deletes the base branch, and GitHub
**auto-closes** any PR pointing at a deleted branch — so #12 and #14 closed
underneath #11 and #13, and #15 was superseded. Recovery was to retarget #16 to
`main` and merge that, bringing the remaining five commits in one merge commit.
Content on `main` is correct and complete; the PR trail is just messy. **Next
time: merge bottom-up without `--delete-branch`, or merge the tip in one go.**

Test suite: **691 tests, 0 failures**, `mix format --check-formatted` clean,
compiles under `--warnings-as-errors`.

---

## 4. Test results

All measured against the **hosted Supabase database** with the real catalogue.
Two vantage points, both real: the dev laptop (RTT median **105 ms**) and the VM
(RTT median **75 ms**).

### 4.1 Interaction times — the headline

Measured at the context layer, not over HTTP. Most pages guard their load with
`if connected?(socket)`, so an HTTP render does no data work — timing HTTP would
measure the wrong thing and flatter every number.

```
           interaction                        before    after    faster
------------------------------------------------------------------------------
Hideout    open page (connected mount)        668 ms     0 ms     >668x
Tasks      open page (connected mount)        638 ms     0 ms     >638x
Tasks      switch game mode PVP->PVE          226 ms     1 ms    226.0x
Tasks      expand a task row                  436 ms     0 ms     >436x
Ammo       open page                          799 ms     0 ms     >799x
Ammo       armor tab                          161 ms     0 ms     >161x
Storyline  open page                          394 ms     3 ms    131.3x
Events     open page                          320 ms     0 ms     >320x
Maps       open page                          283 ms     0 ms     >283x
Items      open page                         1102 ms     2 ms    551.0x
Items      type one search keystroke          280 ms     7 ms     40.0x
Items      type a longer search               217 ms     6 ms     36.2x
Items      search matching nothing             99 ms     7 ms     14.1x
Items      scroll one page                    192 ms     3 ms     64.0x
Items      scroll to page 10                  267 ms     2 ms    133.5x
Items      switch scope tab (quest)           255 ms     3 ms     85.0x
Items      switch sort (class)                264 ms     2 ms    132.0x
Items      expand an item row                1024 ms     0 ms    >1024x
Flea       open page                          730 ms     4 ms    182.5x
Flea       type one search keystroke          296 ms     4 ms     74.0x
Flea       switch to Buyable tab              253 ms     1 ms    253.0x
Flea       scroll one page                    326 ms     2 ms    163.0x
Flea       change PMC level                   544 ms     3 ms    181.3x
------------------------------------------------------------------------------
TOTAL                                        9774 ms    50 ms    195.5x
```

**0 of 23 interactions remain above 100 ms.** Slowest thing left in the app is a
7 ms search keystroke. `before` = cache off + dataset off (production's old
behaviour); `after` = both on and warm.

### 4.2 Cold vs warm, per cached read

```
read                      cold      warm
Items.flea_counts_by_cat  2022 ms   0 ms
Ammo.list_rounds          1537 ms   1 ms
Items.scope_counts        1097 ms   0 ms
Chapters.list_chapters     949 ms   2 ms
Ammo.list_rounds (again)   799 ms   0 ms
Tasks.list_tasks(page)     463 ms   0 ms
Events.list_events         432 ms   0 ms
Armor.list_plates          296 ms   0 ms
Tasks.prereq_map           198 ms   0 ms
Wiki.all_quests            183 ms   0 ms
Hideout.list_modules       135 ms   0 ms
TOTAL                     7312 ms   3 ms
```

### 4.3 Invalidation — verified against real data

Each syncer dropped exactly the entries it owns, including the two second-owner
cases that are easiest to get wrong:

- `HideoutSync` dropped `list_tasks` (because of the `:trader` preload)
- `PricesSync` dropped ammo **availability** but left ammo **ballistics** standing

That second one is the ammo lifetime split working: the ten-minute price tick
invalidates four small `SELECT DISTINCT` sets, not the 1,470 ms read.

Warming verified: cache went **0 → 8 entries** with no request touching it, and
**0 warm failures** across a full Bootstrap.

### 4.4 Dataset equality — 0 mismatches

**152 option combinations**, each run twice (SQL and in-memory) and compared row
for row and in order, against the real 5,449-item catalogue under Supabase's own
collation:

- `list_all_items` — 79 combinations (5 sorts × 5 scopes × 2 modes, 7 searches ×
  3 offsets, level/favourites matrix) — **0 mismatches**
- `list_flea_market_items` — 57 combinations (4 statuses × 6 levels × 2 modes,
  searches × offsets) — **0 mismatches**
- `flea_market_status_counts` — 16 combinations — **0 mismatches**

Ordering byte-identical to SQL.

### 4.5 Dataset build cost, on real data

```
catalogue : 5,449 items   5.5–12.5 s
prices    : 10,620 rows   8.2–13.8 s
memory    : 78.5 MB
ready?    : true for both game modes
```

Against 1,345 MB available on the VM. Memory is not a constraint.

---

## 5. Bug found and fixed during testing (PR #17)

Testing against real data caught something 691 unit tests could not.

Every dataset read cost the same regardless of result size:

```
limit: 1        1 row     35 ms
limit: 40      40 rows    37 ms
narrow search   0 rows    47 ms   <- most expensive request of all
broad search   40 rows    22 ms
```

Cost independent of result size means walking the whole catalogue. `rows/1`
resolved every id into a full `%Item{}` **before** any filter ran, copying ~38 MB
out of ETS per request and discarding almost all of it. The module's own
moduledoc warned about exactly that ("a page copies the ~40 rows it actually
renders") and the implementation did the opposite.

Fixed by holding items twice: full structs touched only for the page, and a
compact projection (folded name/short name, category name, slug, flea levels)
that filtering walks.

```
list_all_items          34.8 ms -> 5.1 ms   (SQL: 347 ms)
list_flea_market_items  22.2 ms -> 3.2 ms   (SQL: 385 ms)
memory                  74.1 MB -> 75.9 MB
```

Equality re-verified after the change: still 0 mismatches.

---

## 6. The database wipe

Performed 2026-08-04 at the user's request — the data was outdated.

**Method** (`mix ecto.reset` cannot be used: the runtime image has no
mix/elixir/psql, and `ecto.drop` would target `DROP DATABASE postgres`, which is
Supabase's own database):

`TRUNCATE ... RESTART IDENTITY CASCADE` over every table in `schemaname =
'public'` **except**:

- `schema_migrations` (73 rows) — truncating it makes the app forget every
  migration ran; the next `migrate` would try to recreate 52 existing tables
- `bug_reports` — user-submitted, the one table no syncer can rebuild

Table list is built from `pg_tables` at run time rather than hardcoded, so it
cannot go stale. `schemaname = 'public'` is load-bearing — it keeps Supabase's
own `auth`, `storage` and `realtime` schemas untouched.

Executed via `docker compose exec -T app /app/bin/eft_buddy rpc "$(cat file)"`.

### Before → after

| | before wipe | after rebuild |
|---|---|---|
| tables / total rows | 52 / 116,423 | 52 |
| `items` | 5,449 | 5,449 |
| `tasks` | 1,016 | 1,016 |
| `item_prices` | 10,620 | 10,620 |
| `sell_for` | 58,199 | 58,199 |
| `buy_for` | 12,547 | 12,547 |
| **`items_barters`** | **3,196** | **1,578** (789 per mode) |

### Rebuild timings, from an empty database

```
18:00  restart
18:01  1/14   ItemsSync
18:02  11/14  everything except the three wiki scrapers
18:04  12/14  ChaptersSync
18:16  13/14  EventsSync
18:44  14/14  WikiSync      <- ~480 quest pages, the long tail
```

**~43 minutes total**, of which Bootstrap proper was ~2 minutes. `WikiSync`
chains off `EventsSync` completion rather than running on a timer.

---

## 7. Findings worth carrying forward

### 7.1 The barter duplication — FIXED, but watch for recurrence

`items_barters` held **3,196** rows against an upstream snapshot of **789 per
mode** (1,578 total) — almost exactly 2×. Because removing the excess would have
deleted >10% of the table, `Sync.Helpers.cleanup_safe?/3` refused to prune on
**every** sync, which is why `/health/sync` had been answering 503 with
`BartersSync: guard_tripped`.

The guard was doing its job correctly the whole time; what it could not do was
say *why*. No amount of normal syncing would have cleared it — a wipe was the
right fix.

**Open question:** what originally wrote both modes' barters into each mode. If
that bug is still live in `EftBuddy.Items.Sync`, the duplication returns on the
next full pipeline run (every 6 hours). **Check `items_barters` — if it is still
1,578 it was a historical artifact and is fixed; if it is back to 3,196 there is
a live bug to find.**

### 7.2 Supabase pooler caps the project at 15 connections

```
FATAL XX000 (EMAXCONNSESSION) max clients reached in session mode
 — max clients are limited to pool_size: 15
```

Both `config/dev.exs` and `runtime.exs` default to `pool_size: 10`. So:

- one instance = 10 of 15, works with 5 spare
- **two instances = 20, exceeds the cap and connections are refused**

Consequences: never run the VM and a laptop instance against the database at the
same time; a rolling deploy that briefly overlaps containers would hit the same
wall; there is little headroom for `pool_count`. **Consider `POOL_SIZE=8` on the
VM** to leave room for a console or a migration job. Currently unset.

### 7.3 Dev and production Postgres do not sort the same way

Measured, on the same item names:

```
Supabase       : ".300 Blackout AP" first   (collation ignores leading punctuation)
local Postgres : "\"Negotiation\" room key" first   (agrees with byte order)
```

This is why `EftBuddy.Items.Dataset` never sorts in Elixir. Postgres produces
the order once at build time and the dataset stores the id list; `Enum.filter/2`
is stable so every derived page keeps it. An implementation using `Enum.sort/1`
would have **passed the local test suite and been wrong in production** — the
same "invisible locally" trap that hid the hideout N+1 for months.

Practical consequence: **anything order-sensitive is untestable locally in the
way that matters.**

### 7.4 The hit-rate metric counts warm builds as misses

A warm build calls `Cache.fetch/4`, misses, computes and stores — so the
warmer's own work lands in the miss column. The number is therefore a poor proxy
for "are users hitting the cache". Worth splitting warm-driven misses from
request-driven ones so the dashboard tile answers the question it appears to.

### 7.5 Connected-mount guard hides page cost

`if connected?(socket)` means the dead HTTP render loads nothing. `curl /hideout`
returned in 3 ms while the page took 7 s after the WebSocket connected. **Never
measure this app's performance over plain HTTP.** Measure the context functions
with the real call shapes.

---

## 8. Current environment state

### VM (`192.168.59.71`, `/opt/eftbuddy`)

- Running **`b974e43`**, verified via `curl localhost:4000/health | jq -r .version`
- Serving `https://eftbuddy.app`
- `CACHE_ENABLED` — **unset, defaults ON**. PRs for the cache are live.
- `ITEM_DATASET` — **unset, defaults OFF**. Items/Flea still on the SQL path.
- `POOL_SIZE` — unset (default 10). See §7.2.
- Database freshly rebuilt, all 14 syncs `ok`
- Stale `.env.bak-20260803-123941` and `.env.bak-20260803-153134` still present
  and **should be deleted** (they contain credentials; `HANDOFF.md` §8 flags this)
- Also untracked on the VM: `ESTADO-E-PENDENTES.md`, `build.log`

### Dev laptop

- **`.env` currently points at SUPABASE, not localhost.** To restore local dev:
  ```
  DB_HOSTNAME=localhost
  DB_NAME=eft_buddy_dev
  DB_PASSWORD=<same value as TEST_DB_PASSWORD>
  ```
  The Supabase password **overwrote** the local one, so the original is gone —
  but `TEST_DB_PASSWORD` is untouched and is the working credential for local
  `postgres` (the whole suite ran against localhost with it).
- Supabase connection values came from the **Session pooler** tab of
  Supabase's "Connect to your project" page:
  `aws-1-eu-west-2.pooler.supabase.com:5432`, user `postgres.<project-ref>`,
  database `postgres`. **Port 5432 (session) is required** — 6543 is the
  transaction pooler, which does not support named prepared statements and would
  need `prepare: :unnamed` in the Repo config.

---

## 9. How to run and test

### Local, against the hosted database

```powershell
Get-Content .env | Where-Object { $_ -match '^\s*[A-Za-z_]\w*=' } |
  ForEach-Object { $k,$v = $_ -split '=',2; Set-Item "env:$k" $v }
$env:START_SYNC='0'      # keeps it read-only; syncers never enter the tree
$env:CACHE_ENABLED='1'
$env:ITEM_DATASET='1'
mix phx.server
```

`START_SYNC=0` costs nothing in coverage: invalidation and warming both hang off
the `[:eft_buddy, :sync, :stop]` telemetry event rather than off the syncers, so
both can be exercised by emitting that event by hand, and warming only reads.

Dashboard at `/dev/dashboard` → **Cache**.

**A server started by the agent does not survive between turns** — background
processes are torn down when the process exits. For a persistent instance, run
it from your own terminal.

### VM deploy

```sh
cd /opt/eftbuddy
git status --porcelain          # '??' entries can block the pull
git pull
GIT_SHA=$(git rev-parse --short HEAD) docker compose build app
# .env edits go HERE, between build and up
docker compose up -d app
curl -s localhost:4000/health | jq -r .version
```

**Never `docker compose down` first** — the release build takes minutes and
`down` means offline for all of it.

Enabling the dataset layer needs no rebuild (the image already has the code):

```sh
echo "ITEM_DATASET=1" >> .env
docker compose up -d app
```

Reverting either half is a flag flip plus `up -d` — seconds, no build.

### Logs

ANSI colour codes break naive greps (`[ItemsSync]` has escape sequences inside
the brackets). Strip first:

```sh
docker compose logs -f app | sed 's/\x1b\[[0-9;]*m//g' | grep -E '\] (ok|error) in '
docker compose logs -f app | sed 's/\x1b\[[0-9;]*m//g' | grep -iE 'refus|failed to warm'
```

### Operator dashboard

```sh
ssh -N -L 4001:127.0.0.1:4001 rcorreia@192.168.59.71
# then http://localhost:4001/dashboard → Cache
```

---

## 10. Tooling traps hit during this session

- **PowerShell 5.1 strips embedded double quotes** when passing to native exes,
  which breaks `ssh host 'docker … rpc "…"'`. Workarounds: build probes with
  Ecto instead of raw SQL strings; write the script to a file with a quoted
  heredoc and use `rpc "$(cat file)"`; or use the Bash tool.
- **`docker compose exec -T` reads stdin** and will swallow the rest of a
  heredoc-driven script — always append `< /dev/null`.
- **`Application.get_env/3`'s default only applies to a MISSING key.** A key set
  explicitly to `nil` returns `nil`, and chaining that through `and` raises
  `BadBooleanError`. Restoring a previously-absent config value in a test
  `on_exit` is exactly how a `nil` gets written. Flag readers now coerce with
  `!!`, and flags are set explicitly in `config/test.exs`.
- **`~s("")` is two quote characters, not one.** Use `~s(")`.
- **Never probe the Repo with `eval`** — `db_connection` is not started under
  `eval` and the Ecto crash dump prints the password. Use `rpc` against the
  running node. `config/dev.exs` now gates
  `show_sensitive_data_on_connection_error` on `local_db?` so a remote target
  cannot dump credentials.

---

## 11. Next steps, in order

1. **Fix the TTL/warming interaction (§2).** Everything else is cosmetic next to
   this — the headline "the server absorbs cold reads" property does not
   currently hold.
2. **Re-measure after the fix** and confirm live entries ≈ 19 specs and the hit
   rate climbs.
3. **Check `items_barters` after the next 6-hour `ItemsSync` cycle** (§7.1). Still
   1,578 = fixed. Back to 3,196 = live bug.
4. **Enable `ITEM_DATASET=1` on the VM** once the cache half looks healthy. It is
   proven equal on real data; the staged rollout is caution, not doubt.
5. **Split warm-driven misses from request-driven ones** in the hit-rate metric
   (§7.4).
6. **`POOL_SIZE=8`** on the VM (§7.2).
7. **Delete the stale `.env.bak-*` files** on the VM, and rotate `DB_PASSWORD` —
   still outstanding from the previous session's plaintext leak.
8. **Restore the local `.env`** to localhost when done testing (§8).
9. Consider coalescing warms harder **during Bootstrap specifically** — a cold
   start currently triggers ~4 catalogue rebuilds as each scope-feeding sync
   completes. Correct, but more work than necessary.
