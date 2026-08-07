# Production Readiness Packet

This packet is the current production-readiness checklist for Hiraeth. It is a runbook pointer and gate map, not a historical task ledger and not a production approval by itself. A release owner must run fresh gates on the final integrated worktree and attach the new release evidence to the release handoff.

Scope guardrails preserved for Hiraeth v1:

- The Docker-to-devenv work is a bounded partial migration: devenv is the preferred local/dev/test and CI-build path, and local development is devenv-only, while Docker remains the current production runtime boundary reference (root `Dockerfile` + `sidecar/Dockerfile` built on Railway). Do not claim production is Nix/devenv-only.
- Production runtime decisions are resolved for Railway (see `docs/production-operations.md`): orchestration target = Railway managed platform, sidecar private network = Railway private networking, backup/restore tooling = `scripts/ops` drill scripts plus Railway managed backups, memory limits = Railway replica limits, logs/observability = Railway logs plus `logger_json`, and rollout/rollback = Railway deploys. Docker remains the current production runtime and service-network boundary reference; do not claim production is Nix/devenv-only or Docker-free.
- LiveView browser-first public product; no React, no Vite SPA, and no separate frontend application.
- No broad public JSON API in v1. Narrow `/health` and `/ready` operations endpoints are operator contracts, not catalog APIs.
- Scraping remains Scrapling-only through the private sidecar; no custom crawler framework is introduced.
- Hiraeth remains a non-commerce discovery catalog; no cart, checkout, public social graph, ratings, shelves, or reviews are in the v1 release surface.
- Provenance, source-ledger, and cover-cache rules are release blockers, not optional audit extras.
- Evidence hygiene remains mandatory: release notes and handoff docs may reference artifact paths, but must not paste raw tokens, cookies, credentials, auth headers, production payloads, private source bodies, or PII.

## Required release gates

Verification is tiered:

- **Layer 0 — local blocking gate:** `mix gate` (wrapped by `make gate`) is the ≤5-min blocking local preflight: compile with warnings-as-errors, unused-deps check, format check, strict Credo, and the fast ExUnit lane. It runs on every change in the developer loop.
- **Layer 1 — parallel CI:** `.github/workflows/ci.yml` runs the `static` (format/Credo/Sobelow/hex.audit) and `test-fast` jobs in parallel on every PR and push to `main`, plus a lean devenv smoke job.
- **Layer 2 — deep lane:** `.github/workflows/deep.yml` runs dialyzer, coverage, the full suite including assets, provenance audit, browser QA, ingestion drills, sidecar pytest, scripts tests, release image builds, and the full devenv readiness graph on merge to `main`, nightly, and manual dispatch.

`mix gate` is not a substitute for the deep lane: the fast blocking gate deliberately omits sobelow/hex.audit (network-dependent, covered by the CI `static` job and the deep `ci` lane), dialyzer, coverage, assets, provenance, browser QA, ingestion drills, sidecar pytest, scripts tests, release image builds, and the full devenv readiness graph. A release owner must run the deep lane before any production-ready claim.

Run the gates below on the final integrated worktree before making any production-ready claim:

1. Fast local preflight for the developer loop: enter a `devenv shell`, then run `mix gate`, plus `mix test.fast` when the release owner wants the explicit fast ExUnit lane. Use the devenv process runner/readiness tasks for local PostgreSQL/Phoenix/sidecar checks.
2. Full local and CI/release assurance: `mix test.full`, `mix ci`, and the GitHub Actions workflow in `.github/workflows/ci.yml`.
3. Sidecar assurance: `cd sidecar && uv run --extra dev pytest -q`.
4. Browser QA: `STRICT_TIMING=1 make test-browser`, which delegates to the stable `scripts/browser_qa.sh` entrypoint and grouped helpers under `scripts/qa/browser/`.
5. Production-ingestion drills: `bash scripts/qa/ingestion/production_ingestion_drill.sh` and `bash scripts/qa/ingestion/production_ingestion_adversarial.sh`.
6. Scope fidelity checks for contracts, routes, assets, sidecar CORS posture, no public JSON API, and no React/Vite/SPA surface.
7. Runtime/debugging review with at least three concrete failure hypotheses ruled in or out against fresh artifacts.
8. Secret and evidence-hygiene review over the new release evidence and docs.
9. Cover-cache preservation check: any gate that can write cover files must run through `scripts/qa/cover_cache_sandbox.sh` or an equivalent temporary worktree copy, and must prove root `priv/static/covers/cache/*` is unchanged.

## Dialyzer PLT persistence

The dialyzer PLT is built once and reused for fast re-runs. The local first build via `make plt` (or `mix dialyzer --plt`) takes ~10-15 min once; every subsequent `mix gate`/`mix dialyzer` reuses the persisted PLT. Dialyxir 1.4 writes the project PLT to `_build/<env>/dialyxir_erlang-<otp>_elixir-<ver>_deps-<env>.plt` (plus a `.hash` sibling); under devenv, `MIX_BUILD_ROOT` places it at `.devenv/mix-build/<env>/`.
The deep-lane CI dialyzer job keeps the `-plt-` cache scoped to the repo's gitignored `priv/plts` convention directory, keyed with the OTP/Elixir-pinned `${{ runner.os }}-plt-27-1.18-${{ hashFiles('mix.lock') }}`, so the `-plt-` and `-build-` cache paths stay disjoint and cannot clobber each other. It tolerates a cold cache: a cache miss simply rebuilds the PLT once.

## Warm re-run protocol

Repeated `make gate` reuses the warm `_build` and the persisted dialyzer PLT, so independent re-verification is fast (~20s warm). `make gate` is the fast independent-verification loop; the deep lane (deep.yml: dialyzer/full-suite-with-coverage/provenance/browser/drills/sidecar/scripts-tests/release-build/devenv-full) still requires the full gates.

## Source documents and runbooks

- Production operations, release, env, migration, backup/restore, rollback, telemetry, alerts, dashboards: `docs/production-operations.md`.
- Contract tiers, public browser contract, internal Ash contract, private sidecar contract, stable operator entrypoints, no public JSON API stance: `docs/contracts.md`.
- Provenance and cover lifecycle, local-cache-only display, takedown handling, and legal-review boundary: `docs/provenance-cover-policy.md`.
- Cleanup policy and root cover-cache denylist: `docs/cleanup-policy.md`.
- Browser QA contract and helper layout: `docs/browser-qa.md`.

## Operator entrypoints after repository consolidation

| Area | Stable operator entrypoint | Implementation/helper location |
| --- | --- | --- |
| Browser QA | `make test-browser` or `scripts/browser_qa.sh` | `scripts/qa/browser/` |
| Production ingestion drill | `bash scripts/qa/ingestion/production_ingestion_drill.sh` | test helper beside the shell script in `scripts/qa/ingestion/` |
| Production ingestion adversarial drill | `bash scripts/qa/ingestion/production_ingestion_adversarial.sh` | sidecar private-host probe and ExUnit helper in `scripts/qa/ingestion/` |
| Provider source backfill | `mix hiraeth.providers.backfill [--dry-run] [--json]` | `lib/mix/tasks/hiraeth.providers.backfill.ex` → `Hiraeth.Ingestion.ProviderBackfill` |
| Provider ingestion | `mix hiraeth.ingest --provider <slug> [--dry-run] [--json] [--wait]` | `lib/mix/tasks/hiraeth.ingest.ex` → `Hiraeth.Ingestion.OperatorCLI` |
| Cover cache | `mix hiraeth.cache_covers [--force]` | `lib/mix/tasks/hiraeth.cache_covers.ex` → `Hiraeth.Covers` |
| Provenance audit | `mix hiraeth.audit_provenance [--seed] [--output-dir <dir>]` | `lib/mix/tasks/hiraeth.audit_provenance.ex` → `Hiraeth.ProvenanceAudit` |
| Real-catalog source artifacts | `mix hiraeth.real_catalog.source_artifacts` | `lib/mix/tasks/hiraeth.real_catalog.source_artifacts.ex` → `Hiraeth.RealCatalog.SourceArtifacts` |
| Real-catalog coverage report | `mix hiraeth.real_catalog.coverage_report` | `lib/mix/tasks/hiraeth.real_catalog.coverage_report.ex` → `Hiraeth.RealCatalog.CoverageReport` |
| Scrape staging | `mix hiraeth.scrape --provider <slug>` | `lib/mix/tasks/hiraeth.scrape.ex` → sidecar + `Hiraeth.RealCatalog` |
| Scrape review | `mix hiraeth.review_scrape --provider <slug>` | `lib/mix/tasks/hiraeth.review_scrape.ex` → `Hiraeth.RealCatalog` |
| Scrape apply | `mix hiraeth.apply_scrape --provider <slug>` | `lib/mix/tasks/hiraeth.apply_scrape.ex` → `Hiraeth.RealCatalog.Importer` |
| Catalog source maintenance | explicit scripts under `scripts/catalog/` | `generate_full_catalog.py`, `generate_full_catalog_deep_vellum.py`, and `extract_fitzcarraldo_catalog.py` |
| Cleanup policy smoke | `make cleanup-policy` | `docs/cleanup-policy.md` and `scripts/qa/cover_cache_sandbox.sh` |
| Full local QA bundle | `make verify` | Make targets and `scripts/verify_summary.sh` |

The grouped helper paths are implementation details unless documented as operator entrypoints above. Prefer the stable entrypoints in release notes, runbooks, and handoffs.

## Operational readiness areas

| Area | Current packet position | Runbook/contract path |
| --- | --- | --- |
| CI | GitHub workflow runs full Phoenix assurance with `mix ci`; fast local `mix gate` is a separate developer preflight. Sidecar pytest remains an adjacent CI/release lane. | `.github/workflows/ci.yml`, `docs/production-operations.md` |
| release/deploy | Phoenix release build, migration, container start, pool sizing, and env setup are documented. | `docs/production-operations.md` |
| env | Required runtime variables are documented; docs must never contain real values. | `docs/production-operations.md`, `.env.example` |
| health/readiness | `/health` and `/ready` are narrow operator endpoints and not a public API. | `docs/contracts.md`, `docs/production-operations.md` |
| backup/restore | Logical PostgreSQL backup and restore drill commands are documented, with restore into a replacement database first. | `docs/production-operations.md` |
| contracts/API tiers | Public browser, stable internal Ash, private sidecar, operator, and future JSON API rules are explicit. | `docs/contracts.md` |
| sidecar exposure/private CORS | Sidecar is private infrastructure; production keeps it on the Railway private network with no public domain or host port, and local devenv binds loopback only; CORS is disabled by default, exact-origin only when configured, and wildcard origins are forbidden. | `docs/contracts.md`, `docs/production-operations.md`, `sidecar/README.md` |
| ingestion control plane | Provider sources/runs, snapshots, record candidates, ingestion events, registry backfill, scheduler, phase workers, quarantine, and replay are durable domain state. | Ash resources and workers under `lib/hiraeth/ingestion/` and `lib/hiraeth/oban/` |
| autonomous ingestion | Scheduled runs follow per-provider `cadence_hours` with the `HIRAETH_SCHEDULED_INGEST` kill-switch (default `true`; `false` disables all autonomous cron). Run the pre-rollout reconciliation and rollout-order steps in the "Autonomous catalog updates" runbook before enabling on Railway. | `docs/production-operations.md` "Autonomous catalog updates" section |
| cover cache/quarantine | Cover candidate cache is local-cache-first with host allowlists, retry/quarantine state, and remote hotlink prevention. Root cleanup must never clean `priv/static/covers/cache/*`. | `docs/provenance-cover-policy.md`, `docs/cleanup-policy.md`, `docs/production-operations.md` |
| telemetry/alerts/dashboards | Telemetry event names, safe metadata rules, alert thresholds, incident response, and dashboard panels are documented. | `docs/production-operations.md` |
| rollback/replay | App image rollback, database restore, snapshot replay, quarantine replay, and retained artifact review are documented. | `docs/production-operations.md` |

## Release owner checklist

Before launch or handoff, confirm:

- All required release gates pass on the final integrated worktree, or blockers are explicitly recorded with owner and recovery path.
- `mix gate` is not treated as a substitute for full release gates; the deep lane (deep.yml) must pass on the final integrated worktree before any production-ready claim.
- Browser QA, ingestion drills, sidecar pytest, and CI use the consolidated script paths above.
- Session secret handling, private sidecar networking, strict CORS, source allowlists, private-IP rejection, and evidence redaction have fresh verification.
- Public pages still render local `/covers/cache/...` URLs or typographic fallbacks, never remote cover URLs.
- `HIRAETH_SCHEDULED_INGEST` is explicitly set (`true` or `false`) in the Railway dashboard, and the "Autonomous catalog updates" pre-rollout reconciliation in `docs/production-operations.md` ran before any enable; rollout-order migration constraints were respected.
- Root `priv/static/covers/cache/*` was not deleted, cleaned, modified, or regenerated by verification.
- Backup/restore and rollback commands are rehearsed against non-production targets before production data changes.
- Release notes describe known risks without exposing secrets, raw source payloads, copied jacket prose, or PII.
