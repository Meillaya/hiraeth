#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ARTIFACT_DIR="${ARTIFACT_DIR:-.omo/evidence/production-grade-ingestion}"
mkdir -p "$ARTIFACT_DIR"
CLEANUP_RECEIPT="$ARTIFACT_DIR/T25-adversarial-cleanup.txt"
: > "$CLEANUP_RECEIPT"

run_mix_tag() {
  local scenario="$1"
  local tag="$2"
  echo "RUN $scenario :: MIX_ENV=test mix test scripts/qa/production_ingestion_adversarial_test.exs --only $tag --seed 0 --trace"
  MIX_ENV=test mix test scripts/qa/production_ingestion_adversarial_test.exs --only "$tag" --seed 0 --trace
  echo "PASS $scenario"
}

run_mix_tag "destructive diff is quarantined/fails closed" "destructive_diff"
run_mix_tag "cover host rejection blocks unsafe host with safe error" "cover_host_rejection"
run_mix_tag "scheduler duplicate prevention prevents duplicate scheduling/runs" "scheduler_duplicate_prevention"
run_mix_tag "admin unauthorized access fails closed without exposing admin data" "admin_unauthorized_access"

echo "RUN sidecar private-host rejection :: cd sidecar && uv run --extra dev python ../scripts/qa/sidecar_private_host_probe.py"
(
  cd sidecar
  uv run --extra dev python ../scripts/qa/sidecar_private_host_probe.py
)
echo "PASS sidecar private-host rejection blocks private host fetch"

{
  echo "cleanup_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cleanup_scope=ExUnit SQL sandbox rolled back adversarial rows; sidecar probe used in-process TestClient with no server PID"
  echo "leftover_t25_tmp_roots=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'hiraeth-t25-*' 2>/dev/null | wc -l | tr -d ' ')"
} > "$CLEANUP_RECEIPT"

echo "PASS cleanup recorded artifact=$CLEANUP_RECEIPT"
echo "PASS production ingestion adversarial drill complete"
