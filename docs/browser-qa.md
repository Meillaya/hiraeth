# Browser QA

`make test-browser` runs `scripts/browser_qa.sh`, which launches the Phoenix LiveView app against a deterministic local demo catalog, drives Chromium in headless mode, and captures desktop/tablet/mobile screenshots plus DOM snapshots under `artifacts/qa/browser/`.

The strict browser contract covers:

- discovery routes: `/`, `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, `/contributors?role=translator`, and book detail pages;
- filter/sort URLs, including `/browse?publisher=deep-vellum&role=translator&format=paperback&sort=newest`;
- malformed query safety via `/browse?q=%25&format=ebook&page=999`;
- New Directions publisher/browse pages with typographic cover fallbacks and no remote image dependency;
- enriched metadata and `data-provenance-motif="source-thread"` on book detail provenance;
- cached cover paths, image decode, mobile overflow, keyboard focus, network/resource failures, and authenticated admin smoke coverage.

Use strict timing for release-style QA:

```sh
STRICT_TIMING=1 make test-browser
```

This is QA-only browser automation. It is not a React, Vite, Playwright, or SPA architecture dependency.
