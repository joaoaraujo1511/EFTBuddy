# Caching batch — testing notes

> Scratch. Companion to `HANDOFF.md` (whose §7 "Step 1 / Step 2" is superseded by
> this file). Delete with the others once this is merged.
>
> Written 2026-08-03. **All six PRs are built.**

---

## The stack

Six branches, stacked — each built on the previous, so the tip contains
everything. `git checkout perf/items-flea-from-memory` tests the lot.

| Branch | Contents |
|---|---|
| `chore/build-sha-health` | `GIT_SHA` build arg → `/health` `version` |
| `perf/cache-observability-warming` | Warmer (own telemetry handler), hit/miss/age metrics, LiveDashboard page, `/health/sync` cache block, `CACHE_ENABLED` kill switch |
| `perf/cache-tier1-list-reads` | Tasks / Ammo / Armor / Events / Chapters / Wiki list reads; ammo split by lifetime; explicit source map |
| `perf/cache-tier1-detail-reads` | Item + task + chapter detail panels, category counts, flea unlock level; cache entry ceiling and expiry sweep |
| `perf/item-dataset-layer` | The in-memory catalogue + price layer + order indexes + scope sets, with row-for-row equality tests. Additive, nothing calls it |
| `perf/items-flea-from-memory` ← **tip** | Items and Flea reads dispatch to it, SQL as fallback |

**691 tests, 0 failures** (two seeds), `mix format --check-formatted` clean,
compiles under `--warnings-as-errors`.

## Testing it locally

```powershell
Get-Content .env | Where-Object { $_ -match '^\s*[A-Za-z_]\w*=' } |
  ForEach-Object { $k,$v = $_ -split '=',2; Set-Item "env:$k" $v }
$env:CACHE_ENABLED = "1"
$env:ITEM_DATASET  = "1"
mix phx.server
```

Dashboard at `/dev/dashboard` → **Cache**. Both flags default OFF, so leaving
them unset reproduces today's behaviour exactly — that is the A/B.

**You will not see a speed difference locally, and that is correct.** The dev
database answers in a fraction of a millisecond; the whole problem is the 75 ms
to London. Locally you are checking that pages, panels, search results, scope
tabs, ordering, paging and counts are *identical* with the flags on and off.

**One expected difference between environments:** a stock local Postgres and
Supabase do not use the same collation. Locally `"Negotiation" room key` sorts
first; on production `.300 Blackout AP` does. The dataset follows whichever
database it is talking to, which is exactly why nothing here sorts in Elixir.

## Rolling it out

The two flags are independent, so they can go out separately:

1. Deploy with **neither** set — everything behaves as today, but `/health`
   gains `version` and the dashboard gains the Cache page.
2. `CACHE_ENABLED=1` (already the prod default). Watch the hit rate.
3. `ITEM_DATASET=1` last, once the cache looks healthy.

Both are `.env` changes plus a restart — seconds, not a release build. Per the
deploy procedure, `.env` edits go **between** `build` and `up -d`.

**Watch the hit-rate tile.** A rate stuck near zero means warm specs are writing
keys nobody reads — the failure that looks exactly like success.

---

## Decisions already made (do not relitigate)

| # | Decision |
|---|---|
| A1 | One ETS row **per item**, filtered with match specs. Never one entry holding the whole 38 MB list — that copies 38 MB into the calling process on every keystroke and is *slower* than the 75 ms database. |
| B | Catalogue and prices are **separate layers**. `PricesSync` runs every 10 min; sharing one entry would force a 3-second full-catalogue reload six times an hour. |
| C | Cache every bounded *data* read. Rendered HTML fragments stay out — LiveView's diff engine already does that job and a fragment cache fights its change tracking. |
| D3 | **Ordering comes from Postgres, once, at warm time.** See below — this is the decision that removes the whole risk class. |
| E | Favourites / `pmc_level` filter in memory against the shared dataset, so nothing user-specific ever enters a cache key. |

---

## D3 — why ordering is not reimplemented

Measured against production, Postgres and Elixir disagree on the **first row**:

```
Postgres:  ".300 Blackout AP"        Elixir:  "\"Negotiation\" room key"
           ".300 Blackout AP ammo…"           "\"The Eye\" mortar strike…"
           ".300 Blackout BCP FMJ"            "#FireKlean gun lube"
```

Postgres's locale collation ignores leading punctuation; `Enum.sort/1` is byte
order. 13 of 5,198 names are also non-ASCII, so case-folding has a second
exposure.

**So do not sort in Elixir.** The warm read already pays for a full catalogue
scan; have it come back `ORDER BY name` and store a precomputed **order index**
— a list of ids, ~40 KB per sort mode. A request then:

1. takes the precomputed order for the active sort;
2. filters it (`Enum.filter` is stable, so relative order survives);
3. partitions favourites to the front (same stable-order trick — this exactly
   reproduces `apply_favorites_first/3`);
4. slices the page;
5. looks up those ~40 rows in the ETS table.

Output is identical to SQL because the ordering *was produced by* the same
collation. No collation library, no NIF, no Unicode edge-case test suite.

**Split by kind of order:**
- `name_asc` / `name_desc` / `class_asc` / `class_desc` — from Postgres, rebuilt on `ItemsSync`.
- Flea's `desc: last_low_price` — **numeric**, so sort it in Elixir on the price
  layer. No collation risk, sub-millisecond for 3,497 rows, and it has to be
  rebuilt every 10 minutes anyway.

---

## What PR 4 built (additive, nothing switches over)

`EftBuddy.Items.Dataset`:

- **Catalogue table** — `{item_id, %Item{}}` with `:category` preloaded, no
  prices. Owned by `ItemsSync`.
- **Price layer** — `{{item_id, mode}, price_row}`, 10,118 rows. Owned by
  `PricesSync`.
- **Order indexes** — `{{:order, sort}, [item_id]}` from Postgres; the flea price
  order computed in Elixir per mode.
- **Scope membership sets** — `%{hideout: MapSet, quest: %{mode => MapSet},
  barter: %{mode => MapSet}, craft: MapSet}`.

  **Cache the membership sets, do not reimplement the predicates.**
  `apply_scope(query, :quest, mode)` is a SQL union over JSONB payload fields
  (`payload->'items'`, `payload->'required_key_ids'`, `payload->>'questItem'`).
  Reproducing that logic in Elixir is the single most likely place to introduce a
  silent divergence. Let Postgres compute the id set; hold the set.

- **A prefolded search field** per item (downcased `name` + `short_name`), so a
  keystroke does not re-downcase 5,198 strings. This is the one piece of "Tier 3"
  that belongs in PR 4 rather than later — the in-memory search needs it to be
  both fast and correct.

- **Equality tests**: for a matrix of `(scope × sort × query × category × favourites
  × pmc_level × offset)`, assert the in-memory result is `==` the SQL result,
  row for row. This is the deliverable that makes PR 5 safe.

**Nothing calls it yet.** PR 4 ships the engine and proves it equals the old one.

## What PR 5 built

`list_all_items/1`, `list_flea_market_items/1` and `flea_market_status_counts/1`
dispatch to the dataset when `ready?/1`, else to the SQL they already had.

On the test-coverage worry: the intricate path is covered by
`DatasetEqualityTest`, which runs **both** implementations and compares them row
for row, and by `DatasetDispatchTest`, which makes the two deliberately disagree
(mutate the database without rebuilding) so the answer reveals which path ran.
Existing Items/Flea tests keep exercising SQL, which is what they were written
for.

---

## Traps found while building PRs 0–3

- **`:telemetry` permanently detaches a handler that raises.** Warming has its
  own handler id for this reason. Anything new hanging off `[:eft_buddy, :sync,
  :stop]` must do the same, and must not raise.
- **Warm with the call site's exact argument shape.** `scope_counts/1` keys on
  the raw argument, and the UI passes the sidebar atoms `:pvp` / `:pve`, not the
  DB strings. A warm using `"regular"` populates a key nobody reads: it works,
  costs a query, and leaves the hit rate at zero. The dashboard's hit-rate tile
  exists to catch exactly this.
- **The second owner is the one you forget.** `list_plates` preloads `:item`
  (ItemsSync), `list_tasks` preloads `:trader` (HideoutSync, not TasksSync).
- **Never `tab2list` a table holding large values.** Both the eviction and the
  expiry sweep use match specs that select keys/timestamps only. A dataset layer
  makes this rule non-negotiable.
- **PowerShell 5.1 strips embedded double quotes** when passing to native exes —
  it breaks `docker … rpc "…"` over ssh. Build probes with Ecto rather than raw
  SQL strings, or use a message file.
- **`Application.get_env/3`'s default only applies to a MISSING key.** A key set
  explicitly to `nil` returns `nil`, and chaining that through `and` raises
  `BadBooleanError`. Restoring a previously-absent config value in a test
  `on_exit` is exactly how a `nil` gets written. Coerce flag readers with `!!`,
  and set flags explicitly in `config/test.exs`.
- **Dev and prod Postgres disagree on collation.** Anything order-sensitive is
  therefore untestable locally in the way that matters — this is the same
  "invisible locally" trap that hid the hideout N+1.

## Measured on production, 2026-08-03

| | |
|---|---|
| Query round trip, median of 10 | **75 ms** (70–88) |
| Items catalogue, full load | 5,198 rows · 3,075 ms · 38.2 MB |
| Flea view, full load | 3,497 rows · 1,656 ms · 31.2 MB |
| Item price rows | 10,118 |
| BEAM total / ETS / binary | 199 MB / 21 MB / 15 MB |
| VM available RAM | 1,282 MB of 1,967 |

Tier 1+2 lands around 300 MB BEAM total. **No VM resize needed.**
