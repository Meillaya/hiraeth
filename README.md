# Hiraeth

Hiraeth is a Phoenix LiveView and Ash catalog for browsing curated independent publisher books with provenance-aware imports, source provenance, local cover caching, and an autonomous ingestion pipeline.

It is still browser-first: the stable v1 surface is the LiveView catalog, not a public JSON API. Public routes include `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, contributor role filters such as `/contributors?role=translator`, and book detail pages.

## What is in the app

- Curated catalog for the approved indie publisher corpus, currently 8,776 deterministic source records across providers such as New Directions, Deep Vellum, Pushkin Press, and more.
- Provenance-aware imports, cover attribution, source artifact reports, and gap states instead of fabricated metadata.
- Local-cache-only public cover display from `/covers/cache/...`; unsafe or missing covers render typographic fallbacks.
- Ash-backed ingestion control plane for provider sources, provider runs, source snapshots, record candidates, diffs, quarantine, replay, and ingestion events.
- Oban-backed autonomous ingestion phases: plan, fetch, normalize, validate, diff, cover-cache, apply, audit, quarantine, replay, and retention cleanup.
- Private-by-default Python sidecar with strict CORS, typed errors, contract snapshots, and URL validation for fetch/scrape adapters.
- Production docs for contracts, operations, readiness, backup/restore, telemetry, alerts, and release handoff.

## Run locally

Local dev runs the nix-profile toolchain directly on PATH (mix, Elixir/OTP, Node, Python/`uv`) plus a standalone PostgreSQL 16 on `127.0.0.1:54320` managed by `scripts/dev/ensure_postgres.sh`. Install the postgres binaries once with `nix profile add nixpkgs#postgresql_16` — the script `die`s with this exact instruction when they are missing from PATH, and nothing is installed into your nix profile automatically. Docker remains the production runtime boundary reference — Railway builds the Phoenix service from the root `Dockerfile` and the sidecar from `sidecar/Dockerfile` — not a local setup path.

The devenv config files (`devenv.nix`, `devenv.yaml`, `flake.nix`, `devenv.lock`, `flake.lock`, `.envrc`) stay in the repo as dormant groundwork for a later revival; local development does not invoke devenv or nix. Reviving that path later means a `devenv shell` for ad hoc Mix commands and the devenv process runner for managed local PostgreSQL, Phoenix, and sidecar processes.

Start and stop the standalone postgres — the first `start` initializes `~/.local/share/hiraeth/pgdata` and bootstraps the `hiraeth_dev`/`hiraeth_test` databases plus the `postgres` role (superuser, password `postgres`):

```sh
bash scripts/dev/ensure_postgres.sh start
bash scripts/dev/ensure_postgres.sh status
bash scripts/dev/ensure_postgres.sh stop
```

Then run the app:

```sh
mix deps.get
mix ash.migrate
MIX_ENV=test mix ash.migrate
mix run priv/repo/seeds.exs
mix phx.server
```

Open <http://localhost:4000>. Postgres data lives in `~/.local/share/hiraeth/pgdata` (`HIRAETH_PGDATA` overrides it) and logs to `~/.local/share/hiraeth/postgres.log`; readiness is probed with `pg_isready -h localhost -p 54320 -U postgres`.

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

Autonomous scheduled ingestion runs on its own per-provider cadence; see the "Autonomous catalog updates" runbook section for what runs when, the `HIRAETH_SCHEDULED_INGEST` kill-switch (off by default locally via devenv), and rollout order.

## Verify/build

Verification is tiered so the fast developer loop stays under five minutes while full release assurance runs at depth:

- **Layer 0 — local blocking gate (`mix gate`, ≤5 min):** `make gate` wraps the `mix gate` alias (compile with warnings-as-errors, unused-deps check, format check, strict Credo, and the fast ExUnit lane). It is the single blocking local preflight for every change.
- **Layer 1 — parallel CI (`static` + `test-fast`):** `.github/workflows/ci.yml` runs the static gates (format/Credo/Sobelow/hex.audit) and the fast test suite (postgres:16 service container) in parallel on every PR and push to `main`.
- **Layer 2 — deep lane (`deep.yml`):** `.github/workflows/deep.yml` runs dialyzer, the full suite as a 3-partition test matrix on merge to `main` and manual dispatch, a nightly coverage job (the explicit `:nightly` opt-in) enforcing the 86.1 floor, plus assets, provenance audit, ingestion drills, sidecar pytest/ruff/pyright/uv-audit, and release image builds.

Frontend correctness is verified by the LiveView and route logic test suites under `test/hiraeth_web/live/` (and the route/controller tests under `test/hiraeth_web/`), which run as part of the ExUnit lanes above; there is no separate browser-level QA lane.

Fast local preflight targets the under-60s developer loop:

```sh
mix gate             # single fast blocking gate
mix test.fast        # fast ExUnit lane, excluding explicit cost tags
```

Full local, CI, and release assurance stays separate and should not be expected to fit the fast-loop budget:

```sh
mix test.full        # complete ExUnit suite minus the opt-in :nightly lane (mix test --only nightly for the nightly sweep)
mix ci               # full Phoenix CI/release assurance
make verify          # provenance audit, verify summary, QA pack
```

Adjacent release/full-verification lanes remain outside the fast gate:

```sh
cd sidecar && uv run --extra dev pytest -q
bash scripts/qa/ingestion/production_ingestion_drill.sh
bash scripts/qa/ingestion/production_ingestion_adversarial.sh
```

Stable operator entrypoints stay at the root or top-level task names (`make verify`, Mix tasks). Implementation helpers are grouped by purpose: catalog maintenance scripts live in `scripts/catalog/`, and production-ingestion drills in `scripts/qa/ingestion/`.

## Cleanup safety

Repository cleanup is allowlist-only and must never delete, clean, modify, or
regenerate the root `priv/static/covers/cache/*` cover cache. Run cache-writing
verification through `scripts/qa/cover_cache_sandbox.sh` so the root cover cache
is hashed before and after the sandboxed command.

## Production notes

The repository includes CI in `.github/workflows/ci.yml` and environment examples in `.env.example`. The public catalog is deployed to Railway at `https://hiraeth-web-production.up.railway.app`: the Phoenix service builds from the root `Dockerfile`, the private Scrapling sidecar builds from `sidecar/Dockerfile`, and Postgres is Railway-managed. Validate deployment networking, secrets, backups, and alerts in the target environment before any further launch.
