#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

POSTGRES_PROCESS="${HIRAETH_POSTGRES_PROCESS:-hiraeth-postgres}"
POSTGRES_HOST="${DATABASE_HOST:-127.0.0.1}"
POSTGRES_PORT="${DATABASE_PORT:-54320}"
POSTGRES_USER="${DATABASE_USER:-postgres}"
POSTGRES_PASSWORD="${DATABASE_PASSWORD:-postgres}"
READY_ATTEMPTS="${HIRAETH_POSTGRES_READY_ATTEMPTS:-60}"
READY_SLEEP="${HIRAETH_POSTGRES_READY_SLEEP:-1}"

# Only the local devenv port (54320) boots/stops postgres via devenv;
# any other DATABASE_PORT (e.g. CI's postgres:16 service container) is
# provided externally and must not invoke nix.
DEVENV_POSTGRES=0
if [[ "${POSTGRES_PORT}" == "54320" ]]; then
  DEVENV_POSTGRES=1
fi

run_devenv() {
  nix run nixpkgs#devenv -- "$@"
}

wait_for_postgres() {
  echo "WAIT postgres :: pg_isready -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER}"

  for ((attempt = 1; attempt <= READY_ATTEMPTS; attempt++)); do
    if PGPASSWORD="${POSTGRES_PASSWORD}" pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}"; then
      echo "PASS postgres ready host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER}"
      return 0
    fi

    if ((attempt < READY_ATTEMPTS)); then
      sleep "${READY_SLEEP}"
    fi
  done

  echo "FAIL postgres did not become ready host=${POSTGRES_HOST} port=${POSTGRES_PORT} user=${POSTGRES_USER}" >&2
  if [[ "${DEVENV_POSTGRES}" == "1" ]]; then
    run_devenv processes logs "${POSTGRES_PROCESS}" || true
  fi
  return 1
}

case "${1:-start}" in
  start)
    if [[ "${DEVENV_POSTGRES}" == "1" ]]; then
      echo "ENSURE postgres :: nix run nixpkgs#devenv -- up -d ${POSTGRES_PROCESS} (log: ${TMPDIR:-/tmp}/devenv-up-${POSTGRES_PROCESS}.log)"
      run_devenv up -d "${POSTGRES_PROCESS}" > "${TMPDIR:-/tmp}/devenv-up-${POSTGRES_PROCESS}.log" 2>&1
    else
      echo "SKIP devenv postgres boot :: DATABASE_PORT=${POSTGRES_PORT} is provided externally"
    fi
    wait_for_postgres
    ;;
  stop)
    if [[ "${DEVENV_POSTGRES}" == "1" ]]; then
      echo "CLEANUP postgres :: nix run nixpkgs#devenv -- processes stop ${POSTGRES_PROCESS}"
      run_devenv processes stop "${POSTGRES_PROCESS}" || true
    else
      echo "SKIP devenv postgres stop :: DATABASE_PORT=${POSTGRES_PORT} is provided externally"
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 64
    ;;
esac
