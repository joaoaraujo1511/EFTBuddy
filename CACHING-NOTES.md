# Caching & performance notes

> Scratch reference — deliberately **not** committed to any PR. Delete when no longer useful.

---

## The underlying problem

Every query to the hosted database costs about **76 ms**, because that is the round-trip
time from the VM to the AWS region Supabase runs in (`eu-west-2`, London). Measured:

```
TCP connect to pooler : 67 / 69 / 79 ms
SELECT 1 (round trip) : 76 ms   (median of 10: 110 ms)
```

Locally, Postgres is on the same machine — a fraction of a millisecond. So **every query
became ~150× more expensive** when the app moved to Supabase.

This is why the VM shows 2% CPU and 400 MB of 1.92 GB RAM while pages take seconds. Those
numbers are healthy. They look healthy *because* the app is idle — sitting in I/O wait for
London. Resource graphs will never show this problem.

**A page doing 20 queries spends ~1.5 s waiting before it renders anything.**

---

## What a cache is (plain terms)

A cache is a copy of an answer kept in the app's own memory.

- **Without one:** every page view asks the database "give me the hideout stations", waits
  ~76 ms for the answer to travel to London and back, uses it, throws it away. The next
  visitor repeats the whole thing.
- **With one:** the first visitor pays the 76 ms. Everyone after reads it from memory in
  ~0.2 ms.

The hard part is not storing the copy. It's knowing **when to throw it away**. Keep it too
long and you serve stale data; too short and you're back to paying the network.

---

## The two ways to expire a cache

### By time (TTL — "time to live")

> "Delete this copy after 20 minutes."

Crude, in both directions: you serve stale data for up to 20 minutes, **and** you re-fetch
data that hasn't changed.

### By event

> "Delete this copy the moment `HideoutSync` finishes writing."

Precise. The copy is thrown away exactly when it stops being true, and never re-fetched
while it's still correct.

**This is the mechanism the implementation uses.** Entries are dropped on the
`[:eft_buddy, :sync, :stop]` telemetry event that `EftBuddy.Sync.Reporter` already emits.

---

## So why keep a TTL at all? (the safeguard)

**Because the event might never fire.**

If a syncer crashes before emitting its event, or a bug detaches the telemetry handler, an
event-only cache holds its copy **forever**.

And that failure is *invisible*:

- no error
- no crash
- pages render perfectly
- ...just with data frozen at some arbitrary moment in the past

You'd only notice days later when prices looked wrong, and you'd have no obvious signal
pointing at the cause.

**The TTL is the seatbelt.** When the event works — which is always, normally — the TTL is
never reached and does nothing at all. When the event silently fails, the damage is capped
at 20 minutes instead of forever.

It costs nothing to have, and it prevents a failure you could not otherwise see.

> This is the "belt and braces" reasoning: event-based invalidation is the **mechanism**;
> the TTL is the **backstop** for the mechanism failing silently.

---

## Freshness is NOT traded away

This is the counter-intuitive part, worth being clear about:

> **Skipping a cache does not give you fresher data. It gives you fresher *reads* of
> equally old data.**

A cached read returns exactly what an uncached read would, because both return *what the
last sync wrote*. The freshness ceiling is the sync interval, and no amount of
cache-avoidance raises it.

If you want fresher data, the lever is the **sync interval**, not the cache. Those are
completely independent decisions and are easy to conflate.

---

## The flea-market case

The original instinct was "cache everything except flea-market, which must be live".

But flea prices were never live — `PricesSync` refreshed every **15 minutes** (now 10). So
the freshest a flea price could ever be was 15 minutes old. A cache invalidated on
`PricesSync` completion would be **exactly as fresh as today**, with none of the round trips.

### Flea needs a different cache *shape*

`Items.list_flea_market_items/1` takes `limit`, `offset`, `flea_status`, `pmc_level` and
`favorite_slugs`, and does filtering/ordering/pagination in SQL. `favorite_slugs` is
**per-operator**.

Caching the *results* would mean one entry per user, per filter, per page — unbounded, and
mostly missing.

The correct approach is **cache the dataset, not the query**: hold the item + price rows in
memory and do the filter/sort/paginate in the app. At ~5,200 items that's single-digit MB,
and per-request work becomes CPU-only — the resource that's sitting idle at 2%.

**This has not been implemented yet.** It's a real restructure and deserves its own PR with
its own measurements.

---

## Sync interval: 15 → 10 minutes

The upstream API refreshes prices roughly every 15 minutes.

Polling faster than the source updates does **not** make data fresher than the source —
nothing can. What it removes is the **phase-misalignment penalty**:

- With both sides on 15-minute cycles, a refresh landing *just after* our tick waits nearly
  a full interval to be picked up.
- Worst-case age = *their* interval + *our* interval.
- At 10 minutes, our half of that drops from 15 to 10.

**Cost:** 50% more calls to an endpoint we don't own, for a refresh that writes only changed
price columns. Backing off later is a config change (`:price_interval`), not a code edit.

---

## The N+1 that broke the hideout page

Separate from caching, and fixed first — because **caching an N+1 hides it rather than
removing it**. The cold path still costs 7 seconds, and every deploy and restart is a cold
path.

`build_initial_modules/0` called `get_level_requirements/2` inside `Enum.map` over all 26
stations. Each call cost one query for the level plus one per preloaded association.

```
list_modules/0        :   98 ms,   1 query,  26 stations
per-station reqs x26  : 7007 ms, 154 queries
─────────────────────────────────────────────
TOTAL                 : 7106 ms over 155 queries
```

It survived review because it is **invisible locally** — the same 155 queries cost ~50 ms
against a local Postgres.

It was also hidden by `hideout_live.ex:21`:

```elixir
modules = if connected?(socket), do: build_initial_modules(), else: []
```

`curl /hideout` returns in 3 ms because the *dead render* loads nothing. The skeleton
arrives instantly, then the page sits there for 7+ seconds after the WebSocket connects.
That's why it looked like "loads forever and never finishes".

### Fix

`Hideout.get_level_requirements_for/1` takes `[{slug, level}]` and resolves the whole grid
in one query plus a fixed number of association preloads.

| | Queries | Local time |
|---|---|---|
| Before (per-station) | **50** | 179 ms |
| After (batched) | **4** | 12 ms |

The query count no longer scales with station count — asserted by a test that fails if a
per-station fetch is reintroduced.

---

## Measured results (hideout grid, real data)

```
cold : 5 queries, 79.9 ms
warm : 0 queries,  0.2 ms
after HideoutSync completes: 5 queries again   ← invalidation works
```

---

## What is cached

All pure reads with **bounded key spaces** (no per-operator arguments):

| Function | Invalidated by |
|---|---|
| `Hideout.list_modules/0` | `HideoutSync` |
| `Hideout.get_level_requirements_for/1` | `HideoutSync` |
| `Hideout.get_total_item_cost/2` | `HideoutSync` |
| `Maps.list_maps/1` | `MapsSync` |
| `Tasks.prereq_map/1` | `TasksSync` |
| `Tasks.traders_with_tasks/1` | `TasksSync` |
| `Items.scope_counts/1` | `ItemsSync` |
| `Items.flea_market_counts_by_category/1` | `ItemsSync`, `PricesSync`, `FleaSettingsSync` |

### Not cached (deliberately)

`Items.list_flea_market_items/1` and other reads taking `favorite_slugs` / `pmc_level` —
see the flea section above.

### Environment behaviour

- **Production:** on.
- **Test:** off. The suite's shape is "insert a fixture, read it back", and a cache with no
  sync to invalidate it would serve one test's value to the next — a failure that would look
  like a data bug rather than a caching one. `EftBuddy.Cache` has its own tests that enable
  it explicitly.
- **Dev:** off. The database is local, so it buys nothing and would only hide writes. Set
  `CACHE_ENABLED=1` to exercise it.

---

## Known limitations

- **Single-node only.** The cache is per-node, in memory. This app runs one instance, so
  that's the whole story. On two nodes each would hold its own copy and they could briefly
  disagree after a sync, because the telemetry event is local.
- **Cache stampede.** Two processes missing the same key will both compute it; the second
  write wins. That's a duplicated read, not a correctness problem. Per-key locking would
  cost more than the occasional double fetch.
- **The real fix for app-wide latency** is still moving the database closer. Caching removes
  repeat reads; it does not remove the 76 ms from a cold read. That was a deliberate
  decision to defer.

---

## Things that are NOT the problem

- **RAM at 400 MB / 1.92 GB** — ~20% used, plenty free. Perfectly healthy.
- **CPU at 2%** — not CPU-bound. This is the *signature* of I/O wait.
- **The recent TLS / certificate PRs** — certificate verification happens once per
  connection at pool setup, not per query. The cost is round-trip time.
