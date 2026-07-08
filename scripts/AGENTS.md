# SCRIPTS KNOWLEDGE BASE

## OVERVIEW
Operational scripts for dev readiness, browser QA, ingestion drills, catalog source refreshes, provenance gates, and cache-safe maintenance.

## STRUCTURE
| Area | Owns |
|---|---|
| `browser_qa.sh` | top-level browser QA orchestrator |
| `dev/ensure_postgres.sh` | devenv-managed Postgres start/stop/readiness |
| `qa/browser/` | CDP/browser checks, seed data, responsive/image/focus/resource audits |
| `qa/ingestion/` | production ingestion drill/adversarial scripts and tests |
| `qa/cover_cache_sandbox.sh` | cache immutability sandbox/hash guard |
| `catalog/` | operator-authorized catalog source refresh scripts |
| `verify_summary.sh` | QA artifact summary gate |

## COMMANDS
```bash
make test-browser
STRICT_TIMING=1 make test-browser
bash scripts/qa/ingestion/production_ingestion_drill.sh
bash scripts/qa/ingestion/production_ingestion_adversarial.sh
bash scripts/qa/cover_cache_sandbox.sh <command>
```

## CONVENTIONS
- Shell scripts use `set -euo pipefail`, deterministic command logging, and `trap cleanup EXIT` where they start services or temp dirs.
- Use `scripts/dev/ensure_postgres.sh` for local DB readiness; do not reintroduce Docker-only Postgres startup in migrated paths.
- Browser QA produces artifacts, not just pass/fail: screenshots, DOM snapshots, timing, network/resource, keyboard focus, overflow, image decode.
- Keep route/viewport matrices and stable DOM markers in sync with LiveView tests.
- Ingestion QA writes receipts under `.omo/evidence/production-grade-ingestion/` and asserts command order/failure short-circuiting.
- Catalog scripts are operator-authorized maintenance tools; preserve provenance fields and source-policy constraints.

## ANTI-PATTERNS
- Blanket cleanup commands touching `priv/static/covers/cache/*`; wrap risky cleanup in `cover_cache_sandbox.sh`.
- Scripts that leave Phoenix/Postgres/Chromium/user-data dirs running after failure.
- Silent network expansion beyond documented providers, fixtures, or Scrapling-backed approved sources.
- Adding browser QA that depends on remote fonts/images/scripts; public captures must stay self-contained.
- Hiding stale Docker-only instructions behind generic “fallback” wording.
