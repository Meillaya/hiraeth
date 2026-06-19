# Hiraeth Quiet Index Design System

Source of truth: `Hiraeth - Quiet Index.dc.html` (`sha256: 730525162576d65c866a7a2620182f477765c31d6c3104a8490c206abdef744f`). This file defines Hiraeth's public production UI language. Phoenix LiveView/HEEx/Tailwind renders it; the reference's React/DC support script and remote Google Fonts are not runtime dependencies.

## 1. Atmosphere

Hiraeth is a quiet editorial archive: restrained, source-forward, bookish, and precise. Interfaces should feel like a curated print index rather than a commercial storefront. Every screen should foreground traceability, provenance, and the distinction between known metadata and absent source data.

## 2. Palette

All public UI color must flow through CSS variables in `assets/css/app.css`.

Light tokens from the reference:
- `--hiraeth-paper`: `#FBFAF7`
- `--hiraeth-surface`: `#ffffff`
- `--hiraeth-warm`: `#F4EFE6`
- `--hiraeth-ink`: `#1B1714`
- `--hiraeth-muted`: `#7a7165`
- `--hiraeth-label`: `#a39a8c`
- `--hiraeth-line`: `#E6E0D4`
- `--hiraeth-thread`: `#A33417`
- `--hiraeth-on-thread`: `#ffffff`
- `--hiraeth-shadow`, `--hiraeth-cover-shadow`, `--hiraeth-cover-shadow-hover`: all editorial depth and cover lift.
- `--hiraeth-sheen`, `--hiraeth-sheen-soft`: inset paper-light details for provenance and empty states.
- `--hiraeth-error-bg`, `--hiraeth-error-ink`, `--hiraeth-error-muted`: system error state colors; do not use raw red utility colors in public components.

Dark tokens from the reference:
- `--hiraeth-paper`: `#14110E`
- `--hiraeth-surface`: `#1B1714`
- `--hiraeth-warm`: `#211d18`
- `--hiraeth-ink`: `#F2EEE6`
- `--hiraeth-muted`: `#9a9184`
- `--hiraeth-label`: `#7a7165`
- `--hiraeth-line`: `#2E2A24`
- `--hiraeth-thread`: `#E05A47`
- `--hiraeth-on-thread`: `#14110E`

## 3. Typography

The reference uses Newsreader for editorial display, Space Grotesk for UI, and Space Mono for provenance labels. Hiraeth must not fetch Google Fonts or other remote fonts at runtime. Until approved self-hosted font assets are checked in, use the declared fallback stacks:
- Serif/display: `ui-serif, Georgia, Cambria, "Times New Roman", Times, serif` behind the named font preferences.
- UI: `ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif` behind the named font preference.
- Mono labels: `ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace` behind the named font preference.

Exact font metrics are a known visual risk without self-hosted font files; layout, hierarchy, spacing, and tone are the acceptance targets.

## 4. Layout and spacing

- Sticky masthead height: `68px`.
- Public container: max width `1180px` (`73.75rem`), desktop gutters about `40px`, smaller responsive gutters on tablet/mobile.
- Home: editorial kicker, large serif headline, italic serif deck, spotlight plus recent acquisitions.
- Browse: desktop three-column grid (`230px / flexible index / 340px`) with sticky filter rail and reader rail; collapse to one column on smaller screens.
- Detail pages: cover and bibliographic/provenance panels with visible source thread.
- Publisher rows: list-first editorial index with small cover thumbnails where sourced cached covers exist.
- Masthead structure mirrors the reference: serif wordmark in ink, accent `Archive` label, primary nav, sourced-volume count, and one compact theme toggle.

## 5. Components

- `qi-header`, `qi-container`, `qi-panel`, `qi-card`, `qi-label`, `qi-kicker`, `qi-button`, `qi-fallback-glow`, and `qi-cover-frame` are canonical public UI primitives.
- Cover images render only from local static cache URLs beginning `/covers/cache/`. Remote `source_url` values are provenance/outbound-link data, never rendered images.
- Missing, uncached, hidden, or ineligible covers render the typographic fallback. Fallbacks are intentional source-state UI, not error states.
- Provenance labels use mono uppercase text, fine borders, and the warm line color.

## 6. Motion and interaction

Keep interaction quiet and GPU-friendly: opacity, color, border-color, box-shadow, and `transform` transitions only. Avoid layout-property animation. Focus rings must be visible and use the accent/thread token.

## 7. Constraints and verification

- No React, Vite SPA, JSON API, Oban, inline scripts, external fonts/scripts/styles, scraping, or remote rendered image dependencies.
- Cover permission/draft metadata is non-blocking for display decisions, but allowlisted official hosts, local cache safety, provenance, attribution, takedown/removal, and auditability remain mandatory.
- Browser QA must capture desktop/tablet/mobile screenshots and DOM; no remote `<img>`, CSS image, font, script, stylesheet, or browser resource/network dependency is allowed on public pages.
