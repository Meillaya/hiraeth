# Browser QA

`make test-browser` runs `scripts/browser_qa.sh`, which launches the Phoenix LiveView app against a deterministic local demo catalog, drives Chromium in headless mode, captures desktop/tablet/mobile screenshots/DOM snapshots, drives real Tab keyboard navigation through Chromium DevTools Protocol, checks focus-state evidence, exercises a CJK/RTL search fixture, and records local network/resource failures in `artifacts/qa/browser/network-errors.json`.

This is QA-only browser automation. It is not a React, Vite, Playwright, or SPA architecture dependency.
