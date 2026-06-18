# Hiraeth

Hiraeth is a Phoenix LiveView and Ash catalog for browsing curated independent publisher book metadata with provenance-aware imports, cover attribution, and fast public discovery.

Current public surfaces include `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, contributor role filters such as `/contributors?role=translator`, and book detail pages with source provenance.

The checked-in pilot catalog includes Deep Vellum, Dalkey Archive, Archipelago Books, New Directions, and Transit Books. New Directions records use explicit no-cover fallbacks until cover-cache permission is recorded; Transit Books records are sourced from official catalog PDFs/pages and keep covers disabled until explicit cover permission is recorded.

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
```

## Verify/build

```sh
mix test
mix compile --warnings-as-errors
STRICT_TIMING=1 make test-browser
make verify
```
