# Wiki fixtures

Trimmed copies of live responses from the
[Escape from Tarkov Wiki](https://escapefromtarkov.fandom.com/wiki/Escape_from_Tarkov_Wiki)
MediaWiki API, captured on 2026-10-18, for the scraper parser tests (audit M24).

- `events_page.wikitext`: the [Events](https://escapefromtarkov.fandom.com/wiki/Events)
  page's wikitext, cut down to its preamble and eight events chosen for the
  parser's edge cases (the past-events divider, a wikitable, piped and
  "Temporary" quest links, events with no "Gameplay Changes" header, non-quest
  "has been added" lines, the PvE note and a date range). Section text is
  unchanged.
- `contributors.json`: a `prop=contributors` response for two quest pages,
  trimmed to four named contributors each. These are public wiki usernames,
  as the app shows them in its credits.
- `file_pages.json`: a `prop=revisions` response for three file pages: one
  declaring `{{Copyright CC-BY-NC-SA 4.0}}`, one empty, one with only a category.

The wiki's text is licensed under
[CC BY-NC-SA 3.0](https://creativecommons.org/licenses/by-nc-sa/3.0/) by its
contributors; these excerpts are used under that licence. To refresh them, re-run
the same API queries (see `EftBuddy.Wiki.Api`) and trim them the same way.
- `the_ticket_sections.json`: three sections of
  [The Ticket](https://escapefromtarkov.fandom.com/wiki/The_Ticket) (the shared
  objectives, one conditional block, and the block shared by all endings), each
  cut to its heading and first lines, for the endgame keep-rule.
