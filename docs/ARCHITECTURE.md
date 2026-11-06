# Architecture

EFT Buddy is a Phoenix LiveView app backed by PostgreSQL. It has no accounts and no
login. The catalogue is rebuilt from upstream feeds rather than maintained by hand.

## Data flow

```
tarkov.dev JSON API ─┐
                     ├─► *.Sync feeds ──► Postgres ──► Cache / Items.Dataset ──► LiveViews
Fandom wiki scrapes ─┘        │                            ▲
                              └─ telemetry [:eft_buddy, :sync, :stop] ─┘
```

## Data feeds

- **`EftBuddy.TarkovApi`** fetches the tarkov.dev JSON API and adapts it to the
  shape the sync code expects.
- **`EftBuddy.Sync.Registry`** is the single list of background feeds. A new feed
  goes here, and a test checks that every `sync.ex` module is registered.
- **`EftBuddy.Sync.Scheduler`** is the shell each feed uses: timer, jitter, global
  lock and crash containment. A feed supplies `do_run/0` and its options.
- **`EftBuddy.Sync.Bootstrap`** runs the first sync at boot, in foreign-key order.
- **`EftBuddy.Sync.Reporter`** records each feed's outcome, and
  **`EftBuddy.Sync.Freshness`** turns that into `/health/sync`.

Child order in `EftBuddy.Application` matters, and is commented there.

## Caching

- **`EftBuddy.Cache`** holds whole-list results that depend only on the database.
  It's invalidated when a feed finishes.
- **`EftBuddy.Items.Dataset`** keeps the item catalogue in ETS for the Items and
  Flea Market pages. It's off unless `ITEM_DATASET=1`, and reads fall back to SQL.

## Per-visitor state

There are no accounts, so the browser holds the durable record:

- **`localStorage`** holds progress, separately for PVP and PVE. Its shape belongs
  to `EftBuddy.Progress`, and pages go through that module.
- **The `eft_prefs` cookie** holds small preferences such as PMC level and faction.
- **`EftBuddy.OperatorSession`** is a per-visitor process holding the live copy,
  created only on a connected mount.
- **`EftBuddyWeb.OperatorState`** injects that state into LiveViews.
- **`EftBuddyWeb.ClientBridge`** carries changes to the browser. Progress merges,
  because `localStorage` is the only durable copy. Preferences replace.
- **`EftBuddy.GameMode`** converts between `"regular"`/`"pve"` and `:pvp`/`:pve`.

## Web layer

- **`EftBuddyWeb.LoadState`** reduces "is this page's data ready?" to
  `:loaded | :loading | :error`.
- **`/health`** checks the database and **`/health/sync`** checks feed freshness.
  They're separate so stale data can't fail a liveness check.
- **The router sets a strict Content-Security-Policy.** No inline scripts, and no
  external scripts or styles in layouts.
- **There is no admin route on the public router.** Operator detail is on
  `EftBuddyWeb.AdminEndpoint`, which is local to the host.
- **`POST /session/reset` must stay a POST**, so a cross-site link can't wipe a
  visitor's tracker.

## Configuration

Everything is read at runtime in `config/runtime.exs`, so one image runs in any
environment. Local development settings are in `.env.dev.example`, and production
ones in `.env.example`.

## Tests

`TEST_DB_*` variables are separate from the `DB_*` ones, so the suite can't touch
another database. Background sync and the caches are off in tests unless a test
turns them on. Tests that need upstream data use `Req.Test` stubs and the payloads
in `test/fixtures/`.
