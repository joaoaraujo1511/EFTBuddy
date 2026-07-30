# Self-hosted fonts

These are the latin-subset `woff2` files for the EFT-Buddy typography
(Oswald display + Inter body), served directly from `priv/static/fonts`
and declared with `@font-face` in `assets/css/app.css`.

Self-hosting (instead of linking Google Fonts in `root.html.heex`) keeps
visitor IPs private, removes a third-party point of failure, and lets the
Content-Security-Policy stay tight (no external font/style origins).

## Licence and attribution

Both faces are licensed under the **SIL Open Font License, Version 1.1**. The OFL
requires its notice and licence text to travel with the font files, so the full
text of each is reproduced alongside them rather than merely linked:

| Face | Files | Copyright | Licence text |
|---|---|---|---|
| Oswald | `oswald-{500,600,700}.woff2` | Copyright 2016 The Oswald Project Authors (https://github.com/googlefonts/OswaldFont) | [`OFL-Oswald.txt`](OFL-Oswald.txt) |
| Inter | `inter-{400,500,600,700}.woff2` | Copyright 2020 The Inter Project Authors (https://github.com/rsms/inter) | [`OFL-Inter.txt`](OFL-Inter.txt) |

**Neither family declares a Reserved Font Name.** Both copyright lines were taken
verbatim from `google/fonts` (`ofl/oswald/OFL.txt`, `ofl/inter/OFL.txt`), and the
only occurrences of the phrase "Reserved Font Name" in either licence file are in
OFL 1.1's own definitions section. That matters practically: without a reserved
name, a modified derivative may keep the family name — so there is nothing extra
to honour here beyond shipping the notices.

These are unmodified latin subsets, repackaged by Fontsource; no glyph, metric or
name-table change has been made.

## Refreshing / changing weights

The files come from the Fontsource CDN (Google Fonts, repackaged as
single-file latin subsets per weight):

```sh
cd priv/static/fonts
for w in 500 600 700; do
  curl -fsSL "https://cdn.jsdelivr.net/fontsource/fonts/oswald@latest/latin-$w-normal.woff2" -o "oswald-$w.woff2"
done
for w in 400 500 600 700; do
  curl -fsSL "https://cdn.jsdelivr.net/fontsource/fonts/inter@latest/latin-$w-normal.woff2" -o "inter-$w.woff2"
done
```

If you add/remove a weight, update the matching `@font-face` block in
`assets/css/app.css`.
