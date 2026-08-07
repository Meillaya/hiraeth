# SCRIPTS KNOWLEDGE BASE

## OVERVIEW
Operational scripts for dev readiness, ingestion drills, catalog source refreshes, provenance gates, and cache-safe maintenance.

## STRUCTURE
| Area | Owns |
|---|---|
| `dev/ensure_postgres.sh` | devenv-managed Postgres start/stop/readiness |
| `qa/ingestion/` | production ingestion drill/adversarial scripts and tests |
| `qa/cover_cache_sandbox.sh` | cache immutability sandbox/hash guard |
| `qa/perf/measure_gates.sh` | perf baseline measurement harness (`make gates:measure`) |
| `ops/` | `db_backup.sh` + `db_restore_drill.sh`; restore drills target a separate DB only, never live |
| `catalog/` | operator-authorized corpus refresh: `generate_full_catalog.py` (live full-corpus refresh), `generate_full_catalog_deep_vellum.py` (helper), `extract_fitzcarraldo_catalog.py` (Scrapling extraction, PEP-723 inline deps) |
| `verify_summary.sh` | QA artifact summary gate |

## COMMANDS
```bash
bash scripts/qa/ingestion/production_ingestion_drill.sh
bash scripts/qa/ingestion/production_ingestion_adversarial.sh
bash scripts/qa/cover_cache_sandbox.sh <command>
make db-backup
make db-restore-drill
make gates:measure
```

## CONVENTIONS
- Shell scripts use `set -euo pipefail`, deterministic command logging, and `trap cleanup EXIT` where they start services or temp dirs.
- Use `scripts/dev/ensure_postgres.sh` for local DB readiness; do not reintroduce Docker-only Postgres startup in migrated paths.
- Ingestion QA writes receipts under `.omo/evidence/production-grade-ingestion/` and asserts command order/failure short-circuiting.
- Catalog scripts are operator-authorized maintenance tools; preserve provenance fields and source-policy constraints.

## ANTI-PATTERNS
- Blanket cleanup commands touching `priv/static/covers/cache/*`; wrap risky cleanup in `cover_cache_sandbox.sh`.
- Scripts that leave Phoenix/Postgres/Chromium/user-data dirs running after failure.
- Silent network expansion beyond documented providers, fixtures, or Scrapling-backed approved sources.
- Hiding stale Docker-only instructions behind generic “fallback” wording.
