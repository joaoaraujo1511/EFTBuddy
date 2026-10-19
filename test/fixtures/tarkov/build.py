"""Rebuild the tarkov.dev test fixtures from the live JSON API.

    python test/fixtures/tarkov/build.py

Downloads the documents EftBuddy.TarkovApi reads, for both game modes, and
writes a small, self-consistent subset of each to test/fixtures/tarkov/<mode>/:
the barters, crafts, tasks (plus their prerequisites), items, stations and one
map that exercise the adapter's edge cases, with each translation document cut
down to the keys those records use. See README.md in this directory.

Standard library only. Expect the picks to need updating when upstream changes
shape; the assertions in test/eft_buddy/tarkov_api_fixture_test.exs read their
expected values from these files, so they follow a refresh on their own.
"""
import gzip, json, os, urllib.request

API = 'https://json.tarkov.dev'
DST = os.path.dirname(os.path.abspath(__file__))
GP, FILTER = '5d235b4d86f7742e017bc88a', '5d1b385e86f774252167b98a'


def load(mode, doc):
    req = urllib.request.Request(f'{API}/{mode}/{doc}', headers={
        'User-Agent': 'EftBuddy fixture builder', 'Accept-Encoding': 'gzip'})
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
        if resp.headers.get('Content-Encoding') == 'gzip':
            raw = gzip.decompress(raw)
    return json.loads(raw)


def strings(obj, acc):
    if isinstance(obj, str):
        acc.add(obj)
    elif isinstance(obj, dict):
        for k, v in obj.items():
            strings(k, acc); strings(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            strings(v, acc)
    return acc


def trim_locale(locale_doc, *docs):
    used = set()
    for d in docs:
        strings(d, used)
    data = locale_doc['data']
    return {'data': {k: v for k, v in data.items() if k in used}}


def write(mode, doc, body):
    os.makedirs(os.path.join(DST, mode), exist_ok=True)
    with open(os.path.join(DST, mode, f'{doc}.json'), 'w', encoding='utf-8', newline='\n') as f:
        json.dump(body, f, ensure_ascii=False, separators=(',', ':'), sort_keys=True)


def build(mode):
    items_doc, items_en = load(mode, 'items'), load(mode, 'items_en')
    tasks_doc, tasks_en = load(mode, 'tasks'), load(mode, 'tasks_en')
    barters, crafts = load(mode, 'barters'), load(mode, 'crafts')
    hideout, hideout_en = load(mode, 'hideout'), load(mode, 'hideout_en')
    maps_doc, maps_en = load(mode, 'maps'), load(mode, 'maps_en')
    traders, traders_en = load(mode, 'traders'), load(mode, 'traders_en')
    en = items_en['data']
    items = items_doc['data']['items']
    name = lambda i: en.get(items[i]['name'], '')

    # --- barters: one fractional-GP Ref barter and one plain barter -------
    b_all = barters['data']
    frac = next(b for b in b_all if any(r['item'] == GP and r['count'] != int(r['count']) for r in b['requiredItems']))
    plain = next(b for b in b_all if all(isinstance(r['count'], int) for r in b['requiredItems']) and b['trader'] != frac['trader'])
    b_keep = [frac, plain]

    # --- crafts: quest-item ingredients, the 0.66 filter, an edition lock --
    c_all = crafts['data']
    c_keep = [next(c for c in c_all if c.get('requiredQuestItems')),
              next(c for c in c_all if any(r['item'] == FILTER for r in c['requiredItems'])),
              next(c for c in c_all if c.get('gameEditions'))]

    # --- tasks: a skill reward (Sniper), a skill objective, required keys --
    t_all = tasks_doc['data']['tasks']
    def has_reward_skill(t, skill):
        return any(e.get('skill') == skill for r in ('startRewards', 'finishRewards') for e in (t.get(r) or {}).get('skillLevelReward', []))
    picks = [next(t for t in t_all.values() if has_reward_skill(t, 'Sniper')),
             next(t for t in t_all.values() if any(o.get('skill') for o in t['objectives'])),
             next(t for t in t_all.values() if any(o.get('requiredKeys') for o in t['objectives']))]
    keep_ids, queue = set(), [t['id'] for t in picks]
    while queue:  # prerequisites, so the snapshot never references a missing task
        tid = queue.pop()
        if tid in keep_ids or tid not in t_all:
            continue
        keep_ids.add(tid)
        queue += [r['task'] for r in t_all[tid].get('taskRequirements', [])]
    t_keep = {i: t_all[i] for i in keep_ids}
    qi_ids = {r['item'] for c in c_keep for r in c.get('requiredQuestItems', [])}
    qi_ids |= {o['questItem'] for t in t_keep.values() for o in t['objectives'] if o.get('questItem')}
    quest_items = {i: v for i, v in tasks_doc['data']['questItems'].items() if i in qi_ids}

    # --- items: everything referenced, plus edge cases --------------------
    want = {GP, FILTER}
    for b in b_keep:
        want |= {r['item'] for r in b['requiredItems']} | {b['offeredItem']['item']}
    for c in c_keep:
        want |= {r['item'] for r in c['requiredItems']} | {c['productItem']['item']}
    want -= qi_ids
    cats = items_doc['data']['itemCategories']
    cat_name = lambda i: en.get(cats.get((items[i].get('categories') or [None])[0], {}).get('name', ''), '')
    by = lambda pred: next((i for i in items if pred(items[i])), None)
    want.add(by(lambda it: 'noFlea' in (it.get('types') or []) and isinstance(it.get('lastLowPrice'), int)))
    want.add(by(lambda it: 'noFlea' not in (it.get('types') or []) and isinstance(it.get('avg24hPrice'), int) and it.get('avg24hPrice') != it.get('lastLowPrice')))
    for cal in ('Caliber9x39', 'Caliber58x42'):
        want.add(by(lambda it: (it.get('properties') or {}).get('propertiesType') == 'ItemPropertiesAmmo' and it['properties'].get('caliber') == cal))
    want.add(by(lambda it: (it.get('properties') or {}).get('propertiesType') == 'ItemPropertiesArmorAttachment' and it['properties'].get('armorType') in ('Heavy', 'Light')))
    for cname in ('Volumetric Throw Weapon', 'Battle Pass Document'):
        want.add(next(i for i in items if cat_name(i) == cname))
    want = {i for i in want if i in items}  # drops picks with no match in this mode
    kept_items = {i: items[i] for i in want}
    cat_ids = {c for it in kept_items.values() for c in (it.get('categories') or [])}
    items_body = {'data': {'items': kept_items,
                           'itemCategories': {i: v for i, v in cats.items() if i in cat_ids},
                           'fleaMarket': items_doc['data']['fleaMarket']}}

    # --- hideout: the stations the crafts use ----------------------------
    st_ids = {c['station'] for c in c_keep}
    hideout_body = {'data': {i: v for i, v in hideout['data'].items() if i in st_ids}}

    # --- maps: one map, with the mobs/containers/weapons it references ----
    mdata = maps_doc['data']
    m = next(v for v in mdata['maps'].values() if v['normalizedName'] == 'factory')
    # Positions lists run to thousands of entries; a handful exercises the adapter.
    m = {k: (v[:12] if isinstance(v, list) and k in ('lootContainers', 'spawns', 'extracts', 'locks', 'hazards', 'switches', 'transits') else v) for k, v in m.items()}
    mob_ids = {b.get('mob') for b in m.get('bosses', [])} | {e.get('mob') for b in m.get('bosses', []) for e in b.get('escorts', [])}
    maps_body = {'data': {'maps': {m['id']: m},
                          'mobs': {i: {k: v[k] for k in ('id', 'name', 'normalizedName', 'imagePortraitLink') if k in v} for i, v in mdata.get('mobs', {}).items() if i in mob_ids},
                          'lootContainers': {i: v for i, v in mdata.get('lootContainers', {}).items() if i in {c.get('lootContainer') for c in m.get('lootContainers', [])}},
                          'stationaryWeapons': {i: v for i, v in mdata.get('stationaryWeapons', {}).items() if i in {w.get('stationaryWeapon') for w in m.get('stationaryWeapons', [])}}}}

    tasks_body = {'data': {'tasks': t_keep, 'questItems': quest_items}}
    trader_fields = ('id', 'name', 'normalizedName', 'imageLink')
    traders_body = {'data': {i: {k: v[k] for k in trader_fields if k in v} for i, v in traders['data'].items()}}

    write(mode, 'items', items_body); write(mode, 'items_en', trim_locale(items_en, items_body))
    write(mode, 'tasks', tasks_body); write(mode, 'tasks_en', trim_locale(tasks_en, tasks_body))
    write(mode, 'barters', {'data': b_keep}); write(mode, 'crafts', {'data': c_keep})
    write(mode, 'hideout', hideout_body); write(mode, 'hideout_en', trim_locale(hideout_en, hideout_body))
    write(mode, 'maps', maps_body); write(mode, 'maps_en', trim_locale(maps_en, maps_body))
    write(mode, 'traders', traders_body); write(mode, 'traders_en', trim_locale(traders_en, traders_body))
    print(mode, 'items', len(kept_items), 'tasks', len(t_keep), 'questItems', len(quest_items),
          'barters', len(b_keep), 'crafts', len(c_keep), 'stations', len(hideout_body['data']))


for mode in ('regular', 'pve'):
    build(mode)
