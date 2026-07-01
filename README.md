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

```sh
mix compile --warnings-as-errors
mix precommit
cd sidecar && uv run --extra dev pytest -q
STRICT_TIMING=1 make test-browser
make verify
bash scripts/qa/production_ingestion_drill.sh
bash scripts/qa/production_ingestion_adversarial.sh
```

The production-grade ingestion completion gate last passed with `mix precommit`, `mix compile --warnings-as-errors`, sidecar pytest, manual QA drills, five-lane review, and a debugging runtime audit. See `.omo/evidence/production-grade-ingestion/ORCHESTRATION-COMPLETE.md` for the full evidence packet.

## Production notes

Start with:

- `docs/contracts.md`
- `docs/production-operations.md`
- `docs/production-readiness.md`
- `docs/provenance-cover-policy.md`

The repository includes CI in `.github/workflows/ci.yml`, environment examples in `.env.example`, and a private sidecar service configuration in `compose.yaml`. No public production deploy has been performed from this workspace; validate deployment networking, secrets, backups, and alerts in the target environment before launch.
