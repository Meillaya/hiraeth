#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

ARTIFACT_DIR="${ARTIFACT_DIR:-.omo/evidence/production-grade-ingestion}"
mkdir -p "$ARTIFACT_DIR"
CLEANUP_RECEIPT="$ARTIFACT_DIR/T25-drill-cleanup.txt"
: > "$CLEANUP_RECEIPT"

ensure_postgres() {
  echo "ENSURE postgres :: docker compose up -d postgres"
  docker compose up -d postgres

  for _ in {1..60}; do
    if docker compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
      echo "PASS postgres ready"
      return 0
    fi

    sleep 1
  done

  echo "FAIL postgres did not become ready"
  docker compose logs --tail 50 postgres
  exit 1
}

run_mix_tag() {
  local scenario="$1"
  local tag="$2"
  echo "RUN $scenario :: MIX_ENV=test mix test scripts/qa/ingestion/production_ingestion_drill_test.exs --only $tag --seed 0 --trace"
  MIX_ENV=test mix test scripts/qa/ingestion/production_ingestion_drill_test.exs --only "$tag" --seed 0 --trace
  echo "PASS $scenario"
}

ensure_postgres
run_mix_tag "provider replay from snapshot reconstructs expected catalog state" "provider_replay"
run_mix_tag "light load/replay idempotency drill reports elapsed/counts" "replay_load_idempotency"

{
  echo "cleanup_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cleanup_scope=ExUnit SQL sandbox rolled back scenario rows; replay retention temp roots removed by on_exit callbacks"
  echo "leftover_t25_tmp_roots=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'hiraeth-t25-drill-*' 2>/dev/null | wc -l | tr -d ' ')"
} > "$CLEANUP_RECEIPT"

echo "PASS cleanup recorded artifact=$CLEANUP_RECEIPT"
echo "PASS production ingestion drill complete"
