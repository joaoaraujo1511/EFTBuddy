# tarkov.dev fixtures

Trimmed copies of the live [tarkov.dev JSON API](https://json.tarkov.dev)
documents that `EftBuddy.TarkovApi` reads, one directory per game mode
(`regular/`, `pve/`). Tests serve them through `Req.Test` (see
`test/support/tarkov_fixtures.ex`), so the adapter is exercised with real
upstream payloads rather than hand-made maps that agree with it by
construction.

- **Captured:** 2026-10-15, from `https://json.tarkov.dev/<mode>/<doc>`.
- **Trimmed to:** the records that exercise the adapter's edge cases, kept
  self-consistent so every reference resolves:
  - a Ref barter priced in fractional GP coins
  - crafts with quest-item ingredients, a fractional (0.66) Water filter, and
    an edition lock
  - tasks with a raw-enum skill reward ("Sniper"), a skill objective and
    required keys, plus every prerequisite they name
  - an item typed `noFlea` that still has a price, and a normally listed item
  - 9x39 and 5.8x42 rounds, an armour plate, and items from the "Volumetric
    Throw Weapon" and "Battle Pass Document" categories
  - the stations those crafts use, and the Factory map with its position
    lists capped
  - every trader, with only the fields the adapter reads

  Each `*_en` translation document keeps only the keys these records use.

## Refreshing

```sh
python test/fixtures/tarkov/build.py
```

The script downloads every document again and rewrites both directories. It
needs Python 3 and nothing else.

The assertions in `test/eft_buddy/tarkov_api_fixture_test.exs` read their
expected values from these files, so a refresh doesn't require editing them.
If upstream changes shape and a pick in `build.py` no longer matches anything,
the script fails at that pick, which tells you what to update.
