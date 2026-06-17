# Browser QA

`make test-browser` runs `scripts/browser_qa.sh`, which launches the Phoenix LiveView app against a deterministic local demo catalog, drives Chromium in headless mode, and captures desktop/tablet/mobile screenshots plus DOM snapshots under `artifacts/qa/browser/`.
Public screenshots and overflow probes force Chromium's preferred color scheme to `light` so the visual QA captures are deterministic and comparable to the read-only `Hiraeth - Quiet Index.dc.html` reference.

The strict browser contract covers:

- discovery routes: `/`, `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, `/contributors?role=translator`, and book detail pages;
- detail-state routes: `/publishers/:slug`, `/contributors/:slug`, `/series/:slug`, canonical `/books/:slug`, `/editions/:slug` redirect, and edition not-found;
- filter/sort URLs, including `/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest`;
- malformed query safety via `/browse?q=%25&format=ebook&page=999`;
- New Directions publisher/browse pages with typographic cover fallbacks and no remote image dependency;
- enriched metadata and `data-provenance-motif="source-thread"` on book detail provenance;
- cached cover paths, image decode, route-specific mobile/tablet overflow for public Quiet Index shells, keyboard focus, network/resource failures, and authenticated admin smoke coverage.

The browser-only QA seed adds a deterministic `Browser QA Series` membership for the existing local `Immigrant` fixture so the public series detail route can be exercised without adding production catalog data or remote cover dependencies.

Use strict timing for release-style QA:

```sh
STRICT_TIMING=1 make test-browser
```

This is QA-only browser automation. It is not a React, Vite, Playwright, or SPA architecture dependency.
