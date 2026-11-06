# EFT Buddy

An unofficial companion web app for *Escape from Tarkov*: quests, items, the flea
market, the hideout, ammo, maps, events and the storyline, kept current from
public data sources.

**Use it at [eftbuddy.app](https://eftbuddy.app).** No accounts and no login. Your
progress lives in your own browser.

> EFT Buddy is a non-commercial fan project and is **not affiliated with or
> endorsed by Battlestate Games**. See [`NOTICE`](NOTICE).

## Contributing

This project is open source so that others can help maintain and improve it. Bug
reports, fixes and ideas are all welcome.

- [Contributing guide](.github/CONTRIBUTING.md)
- [Architecture overview](docs/ARCHITECTURE.md)
- [Open issues](https://github.com/joaoaraujo1511/EFTBuddy/issues)

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

## Project layout

| Path | Contents |
|---|---|
| `lib/eft_buddy/` | Domain logic, data feeds (`*/sync.ex`), caching |
| `lib/eft_buddy_web/` | Router, LiveViews, components |
| `assets/` | JavaScript and CSS |
| `priv/repo/migrations/` | Database schema |
| `test/` | Test suite |
| `config/runtime.exs` | All runtime configuration |

Comments in the code usually explain *why* something is done a certain way. Read
them before changing the code.

## Hosting

[eftbuddy.app](https://eftbuddy.app) is the project's own instance. The licence
allows you to run your own, but this isn't supported. For reference, see
[how eftbuddy.app runs](docs/DEPLOYMENT.md).

## Licence

[GNU AGPL v3](LICENSE). Game names, images and other material belong to their
owners; see [`NOTICE`](NOTICE).
