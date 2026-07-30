# Attribution for the vendored map assets

This is the file `EftBuddy.Maps.Assets` points at. It covers the SVG base maps
in this directory, the projection config synced from the same upstream project,
and the raster tiles and flat renders the viewer hot-links.

The app has no credits page. In the UI, the SVG artwork is credited in a line
on the interactive map viewer itself (see
`EftBuddyWeb.CoreComponents.source_credit/1` and `EftBuddy.Attribution`), and
the site-wide Battlestate and non-commercial statements are in the footer.
Obligations satisfied by a notice rather than by the UI — the MIT licence
below in particular — are satisfied by this file.

## SVG base maps (`*.svg` in this directory)

- **Source:** [Escape from Tarkov SVG Maps Project](https://github.com/the-hideout/tarkov-dev-svg-maps)
- **Creators:** Shebuka, re3mr and the tarkov-dev-svg-maps contributors
- **Licence:** [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)
  ([upstream LICENSE.md](https://github.com/the-hideout/tarkov-dev-svg-maps/blob/main/LICENSE.md))

### Provenance of these exact files

These are the **styled variants tarkov.dev serves** from
`assets.tarkov.dev/maps/svg/`, not the raw files from the upstream repository.
tarkov.dev applies the upstream project's own `replace_style_common.py` /
`style_common.css` post-processing, and it is those processed copies that are
vendored here (verified by checksum: our `customs.svg` matches the
`assets.tarkov.dev` copy exactly, and differs from the repository original).

They are derivative works of the SVG Maps Project either way, so ShareAlike
carries through and the credit above is unchanged — but the pipeline is
recorded here so the bytes can be traced.

### Changes made

- Files renamed from upstream CamelCase to our kebab-case slugs
  (`GroundZero.svg` → `ground-zero.svg`, `StreetsOfTarkov.svg` →
  `streets-of-tarkov.svg`, and so on).
- Styling: as above, applied upstream by tarkov.dev rather than by us.
- The viewer toggles the SVG floor groups through its own floor selector,
  which is the layered structure upstream designed these files for. The SVG
  sources themselves are unmodified in that respect.

### ShareAlike

These modified copies remain licensed under **CC BY-NC-SA 4.0**. Anyone
reusing them from this repository gets them under that same licence, and
must likewise credit the creators above and keep the licence on their own
adaptations.

### NonCommercial

The `NC` term is one reason EFT Buddy carries no advertising, no paid
tiers and no sponsorships. Any donations are voluntary, go to running
costs, and gate no feature or content.

### Prohibited use

The upstream terms forbid using these assets in software that facilitates
cheating or confers an unfair advantage — in-game radar or ESP overlays,
maps built for cheat clients, automation or pixel-bots — and state that
doing so revokes the licence automatically.

EFT Buddy renders these maps as static reference material. It has no
connection to the running game: it does not read game memory, parse game
logs, hook the client, or track live player position. **Any future feature
that would change that would void this licence and must not be built.**

## Map projection config (synced from `maps.json`)

The per-map `transform`, `coordinate_rotation`, `bounds`, `svg_bounds`, zoom
range, floor layers with their height extents, and room labels all come from the
`maps.json` of the [tarkov.dev website](https://github.com/the-hideout/tarkov-dev),
which is MIT licensed.

`EftBuddy.Maps.Sync` fetches that file on every run and stores the config in the
`maps` table, so it is upstream data flowing through the app rather than a copy
committed to this repository. It used to be hand-copied into
`lib/eft_buddy/maps/assets.ex`, which drifted badly — The Lab lost a floor,
Customs lost one, Reserve lost four, and every map's labels were dropped —
so the snapshot was removed. `Maps.Assets` now holds only what upstream cannot
tell us: which SVGs we self-host, the tile mosaic zoom, and a short list of maps
whose upstream projection is known to be miscalibrated.

MIT requires its notice to travel with copies, and the config is copied into our
database and served to clients, so it is reproduced in full:

```
MIT License

Copyright (c) 2019 Oskar Risberg

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Raster map tiles and 2D/3D renders

Not stored here. The Lab, The Labyrinth and Icebreaker tile pyramids are loaded
directly from `assets.tarkov.dev`, and the flat 2D/3D map renders from
`tarkov.dev/maps`, so those images are served by tarkov.dev rather than copied
into this repository. Hot-linking is deliberate: unlike the SVGs, no licence
covers redistributing these, so we must not vendor them.

**These do have named authors.** An earlier version of this file said there was
"no third-party author to name", which was wrong. tarkov.dev's `maps.json`
credits an author (and usually a link) for every tile pyramid and every flat
render, and the app now surfaces them:

- **Interactive tile bases** — credited in the viewer's header line. The Lab and
  The Labyrinth are Tarkov.dev's own; **Icebreaker is
  [TarkovBOT.eu](https://tarkovbot.eu/)**, a third party the old blanket "via
  tarkov.dev" line mis-credited.
- **Flat 2D/3D renders** — credited over the image itself as you switch to them,
  per render. Authors include re3mr, Jindouz, monkimonkimonk, Lorathor, xTycho
  and Shebuka.

These credits are courtesy rather than a licence condition: no CC grant is
claimed for them, because map renders derived from the game's own art remain
Battlestate Games' copyright and tarkov.dev cannot license those onward.

## Marker icons (`markers/`)

**Provenance not yet recorded — to be confirmed by the maintainer.** The **18**
icons in `markers/` — extracts (PMC, scav, shared, transit), hazards (generic,
minefield, mortar, sniper), spawns (PMC, scav, boss, cultist, goons, rogue),
stashes, locks, stationary weapons and switches — carry no source note anywhere
in the repository, and the history available here does not show where they came
from.

(This file said "15" until it was reconciled against the directory: it was
restored verbatim from history, and three spawn icons — cultist, goons and rogue
— were added after the deletion it was restored from. A licence notice that
miscounts the files it covers is exactly the detail a rights holder reads
closely, so the number is checked against `markers/` whenever one is added.)

If they were drawn for EFT Buddy, say so here and they fall under this
repository's own licence. If they were taken from another project, that
project needs crediting on the same terms as everything else in this file.
Until that is settled this file should not be read as claiming ownership of
them.
