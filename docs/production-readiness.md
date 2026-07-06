# Production Readiness Packet

This packet is the current production-readiness checklist for Hiraeth. It is a runbook pointer and gate map, not a historical task ledger and not a production approval by itself. A release owner must run fresh gates on the final integrated worktree and attach the new release evidence to the release handoff.

Scope guardrails preserved for Hiraeth v1:

- LiveView browser-first public product; no React, no Vite SPA, and no separate frontend application.
- No broad public JSON API in v1. Narrow `/health` and `/ready` operations endpoints are operator contracts, not catalog APIs.
- Scraping remains Scrapling-only through the private sidecar; no custom crawler framework is introduced.
- Hiraeth remains a non-commerce discovery catalog; no cart, checkout, public social graph, ratings, shelves, or reviews are in the v1 release surface.
- Provenance, source-ledger, and cover-cache rules are release blockers, not optional audit extras.
- Evidence hygiene remains mandatory: release notes and handoff docs may reference artifact paths, but must not paste raw tokens, cookies, credentials, auth headers, production payloads, private source bodies, or PII.

## Required release gates

Run the gates below on the final integrated worktree before making any production-ready claim:

1. Fast local preflight for the developer loop: `mix precommit` or `mix precommit.fast`, plus `mix test.fast` when the release owner wants the explicit fast ExUnit lane.
2. Full local and CI/release assurance: `mix test.full`, `mix ci`, and the GitHub Actions workflow in `.github/workflows/ci.yml`.
3. Sidecar assurance: `cd sidecar && uv run --extra dev pytest -q`.
4. Browser QA: `STRICT_TIMING=1 make test-browser`, which delegates to the stable `scripts/browser_qa.sh` entrypoint and grouped helpers under `scripts/qa/browser/`.
5. Production-ingestion drills: `bash scripts/qa/ingestion/production_ingestion_drill.sh` and `bash scripts/qa/ingestion/production_ingestion_adversarial.sh`.
6. Scope fidelity checks for contracts, routes, assets, sidecar CORS posture, no public JSON API, and no React/Vite/SPA surface.
7. Runtime/debugging review with at least three concrete failure hypotheses ruled in or out against fresh artifacts.
8. Secret and evidence-hygiene review over the new release evidence and docs.
9. Cover-cache preservation check: any gate that can write cover files must run through `scripts/qa/cover_cache_sandbox.sh` or an equivalent temporary worktree copy, and must prove root `priv/static/covers/cache/*` is unchanged.

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
| Catalog source maintenance | explicit scripts under `scripts/catalog/` | `generate_full_catalog.py`, `generate_full_catalog_deep_vellum.py`, and `extract_fitzcarraldo_catalog.py` |
| Cleanup policy smoke | `make cleanup-policy` | `docs/cleanup-policy.md` and `scripts/qa/cover_cache_sandbox.sh` |
| Full local QA bundle | `make verify` | Make targets and `scripts/verify_summary.sh` |

The grouped helper paths are implementation details unless documented as operator entrypoints above. Prefer the stable entrypoints in release notes, runbooks, and handoffs.

## Operational readiness areas

| Area | Current packet position | Runbook/contract path |
| --- | --- | --- |
| CI | GitHub workflow runs full Phoenix assurance with `mix ci`; fast local `mix precommit`/`mix precommit.fast` is a separate developer preflight. Sidecar pytest remains an adjacent CI/release lane. | `.github/workflows/ci.yml`, `docs/production-operations.md` |
| release/deploy | Phoenix release build, migration, container start, pool sizing, and env setup are documented. | `docs/production-operations.md` |
| env | Required runtime variables are documented; docs must never contain real values. | `docs/production-operations.md`, `.env.example` |
| health/readiness | `/health` and `/ready` are narrow operator endpoints and not a public API. | `docs/contracts.md`, `docs/production-operations.md` |
| backup/restore | Logical PostgreSQL backup and restore drill commands are documented, with restore into a replacement database first. | `docs/production-operations.md` |
| contracts/API tiers | Public browser, stable internal Ash, private sidecar, operator, and future JSON API rules are explicit. | `docs/contracts.md` |
| sidecar exposure/private CORS | Sidecar is private infrastructure; default Compose keeps it service-network-only with no host `ports`; CORS is disabled by default, exact-origin only when configured, and wildcard origins are forbidden. | `compose.yaml`, `docs/contracts.md`, `sidecar/README.md` |
| ingestion control plane | Provider sources/runs, snapshots, record candidates, ingestion events, registry backfill, scheduler, phase workers, quarantine, and replay are durable domain state. | Ash resources and workers under `lib/hiraeth/ingestion/` and `lib/hiraeth/oban/` |
| cover cache/quarantine | Cover candidate cache is local-cache-first with host allowlists, retry/quarantine state, and remote hotlink prevention. Root cleanup must never clean `priv/static/covers/cache/*`. | `docs/provenance-cover-policy.md`, `docs/cleanup-policy.md`, `docs/production-operations.md` |
| admin auth/operator UI | Admin ingestion controls require authentication before mutating registry, runs, quarantine, replay, or scheduling state. | `docs/contracts.md`, admin LiveView/controller code |
| telemetry/alerts/dashboards | Telemetry event names, safe metadata rules, alert thresholds, incident response, and dashboard panels are documented. | `docs/production-operations.md` |
| rollback/replay | App image rollback, database restore, snapshot replay, quarantine replay, and retained artifact review are documented. | `docs/production-operations.md` |

## Release owner checklist

Before launch or handoff, confirm:

- All required release gates pass on the final integrated worktree, or blockers are explicitly recorded with owner and recovery path.
- `mix precommit`/`mix precommit.fast` is not treated as a substitute for full release gates.
- Browser QA, ingestion drills, sidecar pytest, and CI use the consolidated script paths above.
- Admin auth, session secret handling, private sidecar networking, strict CORS, source allowlists, private-IP rejection, and evidence redaction have fresh verification.
- Public pages still render local `/covers/cache/...` URLs or typographic fallbacks, never remote cover URLs.
- Root `priv/static/covers/cache/*` was not deleted, cleaned, modified, or regenerated by verification.
- Backup/restore and rollback commands are rehearsed against non-production targets before production data changes.
- Release notes describe known risks without exposing secrets, raw source payloads, copied jacket prose, or PII.
