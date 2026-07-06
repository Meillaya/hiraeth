# Hiraeth

Hiraeth is a Phoenix LiveView and Ash catalog for browsing curated independent publisher books with provenance-aware imports, source provenance, local cover caching, and an autonomous ingestion pipeline.

It is still browser-first: the stable v1 surface is the LiveView catalog, not a public JSON API. Public routes include `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, contributor role filters such as `/contributors?role=translator`, and book detail pages. Operator and ingestion controls live behind the authenticated admin boundary.

## What is in the app

- Curated catalog for the approved indie publisher corpus, currently 7,013 deterministic source records across providers such as New Directions, Deep Vellum, Pushkin Press, and more.
- Provenance-aware imports, cover attribution, source artifact reports, and gap states instead of fabricated metadata.
- Local-cache-only public cover display from `/covers/cache/...`; unsafe or missing covers render typographic fallbacks.
- Ash-backed ingestion control plane for provider sources, provider runs, source snapshots, record candidates, diffs, quarantine, replay, and ingestion events.
- Oban-backed autonomous ingestion phases: plan, fetch, normalize, validate, diff, cover-cache, apply, audit, quarantine, replay, and retention cleanup.
- Private-by-default Python sidecar with strict CORS, typed errors, contract snapshots, and URL validation for fetch/scrape adapters.
- Production docs for contracts, operations, readiness, backup/restore, telemetry, alerts, and release handoff.

## Run locally

Requirements: Elixir/OTP, Docker, Mix, and `uv` for sidecar tests.

```sh
docker compose up -d postgres
mix deps.get
mix ash.migrate
mix run priv/repo/seeds.exs
mix phx.server
```

Open <http://localhost:4000>.

## Operate ingestion

```sh
mix hiraeth.providers.backfill
mix hiraeth.ingest --provider deep_vellum_official_store --dry-run --json
mix hiraeth.ingest --provider deep_vellum_official_store --wait
mix hiraeth.cache_covers
mix hiraeth.audit_provenance --seed
mix hiraeth.real_catalog.source_artifacts
mix hiraeth.real_catalog.coverage_report
```

Admin users are managed through:

```sh
mix hiraeth.admin.invite --email operator@example.com --role owner --expires-in 15m
```

## Verify/build

Fast local preflight targets the under-60s developer loop:

```sh
mix precommit        # delegates to the fast local gate
mix precommit.fast   # explicit fast gate
mix test.fast        # fast ExUnit lane, excluding explicit cost tags
```

Full local, CI, and release assurance stays separate and should not be expected to fit the fast-loop budget:

```sh
mix test.full        # complete ExUnit suite
mix ci               # full Phoenix CI/release assurance
make verify          # broader local QA bundle
```

Adjacent release/full-verification lanes remain outside fast precommit:

```sh
cd sidecar && uv run --extra dev pytest -q
STRICT_TIMING=1 make test-browser
bash scripts/qa/ingestion/production_ingestion_drill.sh
bash scripts/qa/ingestion/production_ingestion_adversarial.sh
```

Stable operator entrypoints stay at the root or top-level task names (`make test-browser`, `make verify`, Mix tasks, and `scripts/browser_qa.sh`). Implementation helpers are grouped by purpose: catalog maintenance scripts live in `scripts/catalog/`, browser QA helpers in `scripts/qa/browser/`, and production-ingestion drills in `scripts/qa/ingestion/`.

## Cleanup safety

Repository cleanup is allowlist-only and must never delete, clean, modify, or
regenerate the root `priv/static/covers/cache/*` cover cache. See
`docs/cleanup-policy.md`; run cache-writing verification through
`scripts/qa/cover_cache_sandbox.sh` so the root cover cache is hashed before and
after the sandboxed command.

## Production notes

Start with:

- `docs/contracts.md`
- `docs/cleanup-policy.md`
- `docs/production-operations.md`
- `docs/production-readiness.md`
- `docs/provenance-cover-policy.md`

The repository includes CI in `.github/workflows/ci.yml`, environment examples in `.env.example`, and a private sidecar service configuration in `compose.yaml`. No public production deploy has been performed from this workspace; validate deployment networking, secrets, backups, and alerts in the target environment before launch.
