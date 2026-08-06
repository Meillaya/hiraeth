# Self-hosted fonts

All font files in this directory are licensed under the **SIL Open Font License 1.1**
(OFL-1.1). The full license text is in [`OFL.txt`](./OFL.txt) in this directory.
Fonts are served same-origin from `/fonts/...` by `Plug.Static`
(`HiraethWeb.static_paths/0` already declares `fonts`); no remote font hosts are
referenced anywhere in the codebase.

Consumed by `assets/css/app.css` via `@font-face` rules and the
`--hiraeth-font-serif` / `--hiraeth-font-ui` / `--hiraeth-font-mono` CSS tokens.

All files below were downloaded on 2026-08-05 from npm registry tarballs
(registry.npmjs.org) published by the Fontsource project; each package's
`package.json` declares `"license": "OFL-1.1"` and each tarball ships the full
OFL 1.1 text with the family's copyright header.

## Newsreader (serif — `--hiraeth-font-serif`)

- Font version: 1.003 (variable font, `wght` axis 200–800, normal + italic)
- Copyright: Copyright 2020 The Newsreader Project Authors
  (http://github.com/productiontype/Newsreader)
- License: SIL Open Font License 1.1
- Source: npm package `fontsource-variable/newsreader` v5.3.0 (Fontsource scope,
  registry.npmjs.org, license field OFL-1.1)
- Upstream: https://fonts.google.com/specimen/Newsreader
- Files:
  - `newsreader-variable-normal.woff2` (`newsreader-latin-wght-normal.woff2`, latin subset)
  - `newsreader-variable-italic.woff2` (`newsreader-latin-wght-italic.woff2`, latin subset)

## Space Grotesk (UI sans — `--hiraeth-font-ui`)

- Font version: 2.000 (variable font, `wght` axis 300–700, normal)
- Copyright: Copyright 2020 The Space Grotesk Project Authors
  (https://github.com/floriankarsten/space-grotesk)
- License: SIL Open Font License 1.1
- Source: npm package `fontsource-variable/space-grotesk` v5.3.0 (Fontsource scope,
  registry.npmjs.org, license field OFL-1.1)
- Upstream: https://fonts.google.com/specimen/Space+Grotesk
- Files:
  - `space-grotesk-variable-normal.woff2` (`space-grotesk-latin-wght-normal.woff2`, latin subset)

## Space Mono (monospace — `--hiraeth-font-mono`)

- Font version: 1.003 (static weights 400 + 700, normal + italic)
- Copyright: Copyright 2016 The Space Mono Project Authors
  (https://github.com/googlefonts/spacemono)
- License: SIL Open Font License 1.1
- Source: npm package `fontsource/space-mono` v5.3.0 (Fontsource scope,
  registry.npmjs.org, license field OFL-1.1)
- Upstream: https://fonts.google.com/specimen/Space+Mono
- Files:
  - `space-mono-400-normal.woff2` (`space-mono-latin-400-normal.woff2`, latin subset)
  - `space-mono-400-italic.woff2` (`space-mono-latin-400-italic.woff2`, latin subset)
  - `space-mono-700-normal.woff2` (`space-mono-latin-700-normal.woff2`, latin subset)
  - `space-mono-700-italic.woff2` (`space-mono-latin-700-italic.woff2`, latin subset)

## Provenance notes

- Every `.woff2` was verified to start with the `wOF2` magic bytes and its
  name-table version string was read with fontTools before placement here.
- Only the latin subset is shipped (7 files); no other families are permitted.
