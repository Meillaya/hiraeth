# Hiraeth

Hiraeth is a Phoenix LiveView and Ash catalog for browsing curated independent publisher book metadata with provenance-aware imports, cover attribution, and fast public discovery.

Current public surfaces include `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, contributor role filters such as `/contributors?role=translator`, and book detail pages with source-backed bibliographic context.

The checked-in production catalog includes Deep Vellum, Dalkey Archive, Archipelago Books, New Directions, Transit Books, Historical Materialism, Semiotext(e), Phoneme Media, A Strange Object, La Reunion, Fum d'Estampa, NYRB, Tilted Axis Press, McNally Editions, Seven Stories Press, Unnamed Press, and Pushkin Press. Public cover display is local-cache only: eligible cached covers render from `/covers/cache/...`; uncached, missing, hidden, or unsafe covers render source-state typographic fallbacks instead of remote images.

Current completeness statement: Hiraeth imports the full approved checked-in source corpus for the seventeen selected providers, generated from operator-authorized public publisher sources plus bounded ISBN/cover enrichment. The deterministic corpus currently contains 7,013 records with explicit gap states for the few missing covers and for unavailable purchase/review metadata; it is not a fabricated universal bibliography.

## Run locally

Requirements: Elixir/OTP, Docker, and Mix.

```sh
docker compose up -d postgres
mix deps.get
mix ash.migrate
mix run priv/repo/seeds.exs
mix phx.server
```

Open <http://localhost:4000>.

## Import, covers, and audit

```sh
mix run -e 'Hiraeth.RealCatalog.Importer.seed!()'
mix hiraeth.cache_covers
mix hiraeth.audit_provenance --seed
mix hiraeth.real_catalog.source_artifacts
mix hiraeth.real_catalog.coverage_report
```

## Verify/build

```sh
mix test
mix compile --warnings-as-errors
STRICT_TIMING=1 make test-browser
make verify
```
