# Production Readiness Packet: Production-Grade Ingestion

This packet is the T26 handoff for `.omo/plans/production-grade-ingestion.md`. It links the runbooks, contracts, QA evidence, known risks, rollback/replay steps, and owner checklist needed for a release reviewer to trace the T1-T25 ingestion hardening work. It does not claim production-ready status: final readiness is conditional on the final verification wave, the integrated local gates, and the Global Review/Debugging Gate passing after the current dirty worktree is reconciled.

Scope guardrails preserved for Hiraeth v1:

- LiveView browser-first public product; no React, no Vite SPA, and no separate frontend application.
- No broad public JSON API in v1. Narrow `/health` and `/ready` operations endpoints are operator contracts, not catalog APIs.
- Scraping remains Scrapling-only through the private sidecar; no custom crawler framework is introduced.
- Hiraeth remains a non-commerce discovery catalog; no cart, checkout, public social graph, ratings, shelves, or reviews are in the v1 release surface.
- Evidence hygiene for this packet: paths are referenced, but raw tokens, cookies, credentials, auth headers, production payloads, private source bodies, and PII are not pasted.

## Release readiness status

**Conditional handoff, not final production approval.** T1-T25 are marked complete in the plan and have local evidence under `.omo/evidence/production-grade-ingestion/`, but T24/T25 landed after the T23 full gate. The release owner must rerun the integrated final wave before declaring the branch production-ready.

Required final gates still required before a production deploy claim:

1. Re-run full local quality gates on the final integrated worktree: `mix precommit` and `cd sidecar && uv run --extra dev pytest -q`.
2. Re-run the T24 contract/scope fidelity audit against the final routes, assets, sidecar CORS posture, and docs.
3. Re-run the T25 replay/load/security drill using commands that preserve upstream failures with `set -o pipefail`.
4. Complete the Global Review/Debugging Gate with independent review plus at least three runtime/debugging hypotheses ruled in or out against fresh artifacts.
5. Confirm all new T26/T26-repair3 evidence logs exist, are non-empty, and contain no raw secrets or private payloads.
6. Confirm deployment/network controls keep the Scrapling sidecar private and reachable only from trusted runtime infrastructure, and that the committed Compose path does not publish a sidecar host port.

## Source documents and runbooks

- Production operations, release, env, migration, backup/restore, rollback, telemetry, alerts, dashboards: `docs/production-operations.md`.
- Contract tiers, public browser contract, internal Ash contract, private sidecar contract, operator contract, no public JSON API stance: `docs/contracts.md`.
- Original production-grade gap analysis and roadmap: `.omo/ultraresearch/20260629-073853/SYNTHESIS.md`.
- Plan of record and acceptance criteria: `.omo/plans/production-grade-ingestion.md`.
- Evidence root for T1-T25 and this T26 packet: `.omo/evidence/production-grade-ingestion/`.
- T26 claim output: `.omo/start-work/claims/T26.json`; terminal evidence-hygiene third repair claim: `.omo/start-work/claims/T26-repair3.json`. The earlier `.omo/start-work/claims/T26-repair.json`, `.omo/start-work/claims/T26-repair2.json`, `T26-repair-*`, and `T26-repair2-*` PASS artifacts are retained only as historical/superseded hygiene evidence after later reviews found missed token-shaped artifacts and nested T18 gate evidence outside earlier scanner scope.

## Operational readiness areas

| Area | Current packet position | Runbook/contract path | Evidence trace |
| --- | --- | --- | --- |
| CI | GitHub workflow and local gate expectations exist for Phoenix, assets, and sidecar. | `.github/workflows/`, `docs/production-operations.md` | `.omo/evidence/production-grade-ingestion/T1-*`, `T23-*` |
| release/deploy | Phoenix release build, migration, container start, pool sizing, and env setup are documented. | `docs/production-operations.md` | `.omo/evidence/production-grade-ingestion/T2-*`, `T23-*` |
| env | Required runtime variables are documented; docs must never contain real values. | `docs/production-operations.md`, `.env.example` | `.omo/evidence/production-grade-ingestion/T2-*`, `T26-doc-hygiene.log`, `T26-repair3-evidence-hygiene.log` |
| health/readiness | `/health` and `/ready` are narrow operator endpoints and not a public API. | `docs/contracts.md`, `docs/production-operations.md` | `.omo/evidence/production-grade-ingestion/T3-*`, `T24-*` |
| backup/restore | Logical PostgreSQL backup and restore drill commands are documented, with restore into a replacement database first. | `docs/production-operations.md` | `.omo/evidence/production-grade-ingestion/T2-*`, `T23-clean-db.log` |
| contracts/API tiers | Public browser, stable internal Ash, private sidecar, operator, and future JSON API rules are explicit. | `docs/contracts.md` | `.omo/evidence/production-grade-ingestion/T4-*`, `T7-*`, `T24-*` |
| sidecar exposure/private CORS | Sidecar is private infrastructure; default Compose keeps it service-network-only with no host `ports`; CORS is disabled by default, exact-origin only when configured, and wildcard origins are forbidden. | `compose.yaml`, `docs/contracts.md`, `sidecar/README.md` | `.omo/evidence/production-grade-ingestion/T5-*`, `T6-*`, `T7-*`, `T24-sidecar-cors.log`, `T25-adversarial.log` |
| ingestion control-plane resources | Provider source/run, snapshots, record candidates, ingestion events, and registry backfill are durable domain state. | `.omo/plans/production-grade-ingestion.md`, Ash resources under `lib/hiraeth/ingestion/` | `.omo/evidence/production-grade-ingestion/T8-*`, `T9-*`, `T10-*`, `T11-*`, `T12-*` |
| scheduler | Scheduler creates due provider runs with duplicate-run defenses and observable telemetry. | `docs/production-operations.md`, scheduler code under `lib/hiraeth/ingestion/` and `lib/hiraeth/oban/` | `.omo/evidence/production-grade-ingestion/T13-*`, `T21-*`, `T25-*` |
| phase workers | Fetch, normalize, validate, diff, apply, audit, quarantine, tombstone, and replay phases are separated for retries/replay. | `.omo/plans/production-grade-ingestion.md`, phase worker modules under `lib/hiraeth/ingestion/phases/` | `.omo/evidence/production-grade-ingestion/T14-*`, `T15-*`, `T17-*`, `T25-*` |
| snapshots/retention | Retained snapshots carry checksums, source metadata, retention metadata, and replay hooks. | `docs/production-operations.md`, source snapshot resources | `.omo/evidence/production-grade-ingestion/T11-*`, `T14-*`, `T25-drill.log` |
| record candidates/diff/quarantine/replay | Candidate fingerprinting, diff classification, quarantine decisions, destructive-approval checks, and replay drills are evidenced. | `docs/production-operations.md`, `docs/contracts.md` | `.omo/evidence/production-grade-ingestion/T12-*`, `T15-*`, `T20-*`, `T25-*` |
| cover cache/quarantine | Cover candidate cache is local-cache-first with host allowlists, retry/quarantine state, and remote hotlink prevention. | `docs/provenance-cover-policy.md`, `docs/production-operations.md` | `.omo/evidence/production-grade-ingestion/T16-*`, `T21-*`, `T25-adversarial.log` |
| admin auth/operator UI | Admin ingestion controls require authentication before mutating registry, runs, quarantine, replay, or scheduling state. | `docs/contracts.md`, admin LiveView/controller code | `.omo/evidence/production-grade-ingestion/T18-*`, `T19-*`, `T20-*`, `T23-admin-*`, `T25-adversarial.log` |
| telemetry/alerts/dashboards | Telemetry event names, safe metadata rules, alert thresholds, incident response, and dashboard panels are documented. | `docs/production-operations.md` | `.omo/evidence/production-grade-ingestion/T21-*`, `T22-*`, `T23-*` |
| rollback/replay | App image rollback, database restore, snapshot replay, quarantine replay, and retained artifact review are documented. | `docs/production-operations.md`, this packet | `.omo/evidence/production-grade-ingestion/T14-*`, `T15-*`, `T20-*`, `T25-*` |
| known risks | Residual risks are explicit below and must be signed off before release. | This packet | `.omo/evidence/production-grade-ingestion/T24-*`, `T25-*`, `T26-*` |

## QA evidence matrix T1-T25

For each task, the full artifact set is the matching prefix under `.omo/evidence/production-grade-ingestion/` (for example, `T14-*` includes its gate reviews, repairs, reruns, adversarial probes, and manual QA matrix). The primary paths below are the shortest trace to the acceptance scenarios; reviewers may inspect the full prefix set when reconciling a gate.

| Task | Readiness contribution | Primary evidence paths |
| --- | --- | --- |
| T1 | CI baseline for Phoenix, sidecar, and assets. | `.omo/evidence/production-grade-ingestion/T1-happy.log`, `T1-failure.log`, `T1-sidecar.log`, full set `T1-*` |
| T2 | Production release, env, backup, and restore runbooks. | `.omo/evidence/production-grade-ingestion/T2-happy.log`, `T2-red.log`, full set `T2-*` |
| T3 | Phoenix health/readiness endpoints. | `.omo/evidence/production-grade-ingestion/T3-tests.log`, `T3-health.http`, `T3-ready-failure.http`, full set `T3-*` |
| T4 | Contract tiers and typed public catalog projections. | `.omo/evidence/production-grade-ingestion/T4-happy.log`, `T4-projection-smoke.log`, `T4-routes.log`, full set `T4-*` |
| T5 | Private-by-default sidecar and strict CORS. | `.omo/evidence/production-grade-ingestion/T5-happy.log`, `T5-failure.log`, full set `T5-*` |
| T6 | Typed sidecar error taxonomy and stricter models. | `.omo/evidence/production-grade-ingestion/T6-happy.log`, `T6-failure.log`, `T6-openapi-snapshot.log`, full set `T6-*` |
| T7 | Sidecar contract snapshots. | `.omo/evidence/production-grade-ingestion/T7-happy.log`, `T7-failure.log`, `T7-malformed.log`, full set `T7-*` |
| T8 | Failing-first tests for ingestion control-plane resources. | `.omo/evidence/production-grade-ingestion/T8-red.log`, `T8-worker-done-claim.json`, full set `T8-*`; `T8-no-impl-before-red.log` is retained only as a silent command-exit receipt. |
| T9 | Ash resources and migrations for the ingestion control plane. | `.omo/evidence/production-grade-ingestion/T9-happy.log`, `T9-validation-failure.log`, `T9-migration-cycle.log`, full set `T9-*` |
| T10 | Provider registry backfill from existing data and manifests. | `.omo/evidence/production-grade-ingestion/T10-dry-run.json`, `T10-idempotent.log`, `T10-gate-review-2.md`, full set `T10-*` |
| T11 | Source snapshots and artifact retention metadata. | `.omo/evidence/production-grade-ingestion/T11-happy.log`, `T11-path-failure.log`, full set `T11-*` |
| T12 | Record candidates, fingerprints, diffs, and quarantine decisions. | `.omo/evidence/production-grade-ingestion/T12-happy.log`, `T12-quarantine-failure.log`, `T12-gate-review-rerun.md`, full set `T12-*` |
| T13 | Provider scheduler and run planner. | `.omo/evidence/production-grade-ingestion/T13-happy.log`, `T13-duplicate-failure.log`, `T13-gate-review-rerun.md`, full set `T13-*` |
| T14 | Fetch, normalize, validate, and diff phase workers. | `.omo/evidence/production-grade-ingestion/T14-happy.log`, `T14-failure.log`, `T14-manual-qa-matrix.md`, full set `T14-*` |
| T15 | Apply, audit, quarantine, tombstone, and replay phase workers. | `.omo/evidence/production-grade-ingestion/T15-happy.log`, `T15-failure.log`, `T15-manual-qa-matrix.md`, full set `T15-*` |
| T16 | Cover candidate retry/quarantine. | `.omo/evidence/production-grade-ingestion/T16-happy.log`, `T16-failure.log`, `T16-manual-qa-matrix.md`, full set `T16-*` |
| T17 | Operator Mix task compatibility. | `.omo/evidence/production-grade-ingestion/T17-happy.log`, `T17-dry-run.json`, `T17-failure.log`, full set `T17-*` |
| T18 | Authentication and authorization boundary for admin ingestion controls. | `.omo/evidence/production-grade-ingestion/T18-happy.log`, redacted `T18-anon.http`, `T18-manual-qa-matrix.md`, full set `T18-*` |
| T19 | Admin provider registry and run timeline LiveViews. | `.omo/evidence/production-grade-ingestion/T19-happy.log`, `T19-browser-qa.log`, `T19-repair3-screenshot.png`, full set `T19-*` |
| T20 | Admin quarantine, retry, replay, and audit export flows. | `.omo/evidence/production-grade-ingestion/T20-happy.log`, `T20-failure.log`, `T20-quarantine.png`, full set `T20-*` |
| T21 | Telemetry, alerts documentation, and operator dashboards. | `.omo/evidence/production-grade-ingestion/T21-happy.log`, `T21-failure.log`, `T21-manual-qa-matrix.md`, full set `T21-*` |
| T22 | Ash missed-notification warning policy. | `.omo/evidence/production-grade-ingestion/T22-happy.log`, `T22-manual-qa-matrix.md`, `T22-gate-command-summary.log`, full set `T22-*`; `T22-warning-check.log` is retained only as a silent command-exit receipt. |
| T23 | Full local quality gates before later T24/T25 changes. | `.omo/evidence/production-grade-ingestion/T23-precommit.log`, `T23-sidecar-pytest.log`, `T23-clean-db.log`, full set `T23-*` |
| T24 | Contract and scope fidelity audit. | `.omo/evidence/production-grade-ingestion/T24-happy.log`, `T24-forbidden.log`, `T24-sidecar-cors.log`, full set `T24-*` |
| T25 | Replay, load, and security drills. | `.omo/evidence/production-grade-ingestion/T25-drill.log`, `T25-adversarial.log`, `T25-gate-review.md`, full set `T25-*` |

Silent-pass artifact note: zero-byte historical logs in the evidence root are not used as standalone primary proof in this packet unless explicitly labeled as command-exit receipts. Reviewers should prefer the adjacent non-empty logs, manual QA matrices, command summaries, or DoneClaim artifacts listed above.

Evidence-hygiene repair3 note: T26 repair3 supersedes the earlier `T26-repair-*` and `T26-repair2-*` PASS artifacts for terminal hygiene after the rerun2 review found nested T18 gate evidence missed by a non-recursive repair2 scan. Repair3 recursively scans every UTF-8 text file under `.omo/evidence/production-grade-ingestion/`, including nested evidence directories such as `.omo/evidence/production-grade-ingestion/T18-gate-logs/`, plus `.omo/start-work/claims/**/*.json` and `docs/production-readiness.md`; it skips only binary/non-UTF8 files and reports counts. Repair3 redacts token-shaped invite/admin/session values, token-bearing admin/session URLs, SQL/debug session-token or token-hash output, cookie/auth/csrf/password/API-key patterns, and misleading raw-label fields while preserving semantics through `<redacted-... length=N sha256=...>` placeholders and redacted labels. The terminal repair3 artifacts are `T26-repair3-evidence-hygiene.log`, `T26-repair3-post-redaction-inventory.log`, `T26-repair3-evidence-matrix-audit.log`, `T26-repair3-manual-qa.md`, `T26-repair3-adversarial-probes.log`, and `T26-repair3-stop-hook-verification.log`.

## Rollback and replay steps

Application rollback:

1. Stop the new rollout and preserve the currently healthy production instances.
2. Start the previous known-good image with the same runtime configuration names and current database URL.
3. Verify `/health`, `/ready`, database connectivity, admin login boundary, and sidecar private reachability from the runtime network.
4. Shift traffic back to the previous image.
5. Capture the incident reason, image tags, migration status, and operator actions in the release ticket.

Data rollback/restore:

1. Stop Phoenix writers and ingestion schedulers before data replacement.
2. Restore the latest verified PostgreSQL backup into a replacement database, not over the active database.
3. Run release migration inspection against the replacement database.
4. Start the previous known-good image against the restored database and repeat health/readiness checks.
5. Repoint production only after the incident commander approves the data replacement.

Replay and quarantine recovery:

1. Identify `provider_run_id`, `provider_source_id`, snapshot checksum, adapter version, candidate IDs, and quarantine decision rows from the admin operator UI or database-backed run timeline.
2. Preserve retained source snapshots, candidate rows, ingestion events, and cover candidate state; do not delete failed runs during diagnosis.
3. Replay idempotent fetch/normalize/validate/diff phases first. Apply, tombstone, destructive diff, and replay actions require authenticated operator approval and review notes.
4. For cover incidents, repair allowlists, cache permissions, maximum byte-size settings, or thumbnailer behavior before retrying cover candidate cache work.
5. Confirm public LiveView pages render local cached covers or typographic fallbacks; do not hotlink remote covers as a workaround.

## known risks and residual operating notes

- Broad dirty worktree: T1-T25 introduced many modified and new files. Final integrated gates must run on the exact release branch before any production-ready claim.
- Sidecar privacy depends on deployment/network controls in addition to app-level CORS defaults and the committed Compose default. The release owner must verify private ingress, service network policy, and absence of public sidecar exposure or default sidecar host-port publication.
- T25 evidence includes a pipefail watch: future replay/load/security commands must run under a parent shell with `set -o pipefail` so tee does not mask a failed drill.
- T25 replay evidence demonstrates retained snapshot/payload state. Final public projection verification for replayed records belongs to the final wave.
- Python sidecar probe warning suppression is cleanup-only; warning count alone is not release-blocking when tests pass and no runtime behavior changes.
- T23 full local quality gates passed before later T24/T25 changes. Treat T23 as historical evidence, not a substitute for final integrated gates.
- Some evidence artifacts are screenshots, JSON, HTTP captures, or invite/admin QA logs. Reviewers must inspect paths without copying raw contents into release notes; any session-cookie, invite-token, authorization, CSRF, or credential material in retained evidence must stay redacted.

## Owner checklist

Release owner:

- Confirm final branch and dirty worktree state are expected; no unrelated local changes are included.
- Re-run integrated gates and store fresh evidence under `.omo/evidence/production-grade-ingestion/`.
- Confirm migration order, backup, restore drill expectations, and rollback image are ready.
- Confirm release notes state that readiness is conditional until Global Review/Debugging Gate passes.

Operations owner:

- Provision required runtime environment variables in the secret store, not in git.
- Verify PostgreSQL backup location, retention, restore permissions, and replacement-database drill path.
- Verify `/health`, `/ready`, Phoenix logs, Oban queue visibility, and database pool capacity.
- Verify alert routing for scheduler, queue latency, phase failures, sidecar errors, candidate spikes/drops, stale quarantine, and cover failures.

Security owner:

- Verify admin auth, session secret handling, private sidecar networking, strict CORS, source allowlists, private-IP rejection, and evidence redaction.
- Verify no public JSON API, cart/checkout, social, review, rating, shelf, React, or Vite SPA scope creep in final routes/assets.
- Verify docs and evidence do not paste tokens, cookies, credentials, production payloads, source HTML, or PII.

Ingestion owner:

- Verify provider scheduler status, duplicate-run defenses, phase worker retry boundaries, retained snapshots, candidate diffs, quarantine review, replay/tombstone safeguards, and cover candidate quarantine.
- Confirm launch-critical providers have current manifests, expected record counts, and rate-limit posture.
- Confirm destructive changes require operator approval and review notes.

Product owner:

- Confirm Hiraeth v1 remains a curated non-commerce LiveView catalog.
- Confirm public browser contract changes, if any, are documented before release.
- Confirm final evidence is enough for handoff without exposing sensitive data.
