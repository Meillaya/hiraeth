#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

# Standalone postgres management: local dev runs the nix-profile toolchain on
# bare PATH plus a standalone PostgreSQL 16 on 127.0.0.1:54320 managed here.
# DATABASE_PORT unset or 54320 means the local standalone postgres is expected
# and is managed here. Any other DATABASE_PORT (CI=5432, the GitHub
# postgres:16 service container) is provided externally and must never be
# touched locally — the CI skip branch is load-bearing for deep.yml provenance
# + ingestion-drills jobs.
PGDATA="${HIRAETH_PGDATA:-$HOME/.local/share/hiraeth/pgdata}"
PGLOG="${HIRAETH_PGLOG:-$HOME/.local/share/hiraeth/postgres.log}"
SOCKET_DIR="$HOME/.local/share/hiraeth"
READY_ATTEMPTS="${HIRAETH_POSTGRES_READY_ATTEMPTS:-60}"
READY_SLEEP="${HIRAETH_POSTGRES_READY_SLEEP:-1}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_binaries() {
  local missing=()
  local bin
  for bin in initdb pg_ctl pg_isready psql; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
      missing+=("${bin}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "postgres binaries missing from PATH (${missing[*]}). Install PostgreSQL 16 once with: nix profile add nixpkgs#postgresql_16"
  fi
}

is_local_postgres() {
  # Unset DATABASE_PORT or 54320 -> local standalone postgres (managed here).
  # Anything else -> externally provided server (never touch local pg_ctl).
  [[ -z "${DATABASE_PORT:-}" || "${DATABASE_PORT}" == "54320" ]]
}

pg_isready_args() {
  echo "-h ${DATABASE_HOST:-localhost} -p ${DATABASE_PORT:-54320} -U postgres"
}

pg_running() {
  # shellcheck disable=SC2086
  pg_isready $(pg_isready_args) >/dev/null 2>&1
}

wait_for_postgres() {
  echo "WAIT postgres :: pg_isready $(pg_isready_args)"

  for ((attempt = 1; attempt <= READY_ATTEMPTS; attempt++)); do
    # shellcheck disable=SC2086
    if pg_isready $(pg_isready_args); then
      echo "PASS postgres ready host=${DATABASE_HOST:-localhost} port=${DATABASE_PORT:-54320} user=postgres"
      return 0
    fi

    if ((attempt < READY_ATTEMPTS)); then
      sleep "${READY_SLEEP}"
    fi
  done

  echo "FAIL postgres did not become ready within ${READY_ATTEMPTS} attempt(s)" >&2
  return 1
}

first_init() {
  # PG_VERSION marks an initialized data directory; nothing to do on re-runs.
  [[ -f "${PGDATA}/PG_VERSION" ]] && return 0

  require_binaries
  mkdir -p "${SOCKET_DIR}"

  echo "INIT postgres :: initdb --locale=C --encoding=UTF8 --username=postgres -D ${PGDATA}"
  initdb --locale=C --encoding=UTF8 --username=postgres -D "${PGDATA}"

  echo "BOOTSTRAP postgres :: create hiraeth_dev + hiraeth_test + ALTER ROLE postgres"
  pg_ctl -D "${PGDATA}" -l "${PGLOG}" -w start -o "-c listen_addresses=127.0.0.1 -p 54320 -c unix_socket_directories=${SOCKET_DIR}"
  trap 'pg_ctl -D "${PGDATA}" -m fast -w stop >/dev/null 2>&1 || true' EXIT

  psql -h 127.0.0.1 -p 54320 -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE DATABASE hiraeth_dev;
CREATE DATABASE hiraeth_test;
ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';
SQL

  pg_ctl -D "${PGDATA}" -m fast -w stop
  trap - EXIT
}

case "${1:-start}" in
  start)
    if is_local_postgres; then
      require_binaries
      first_init

      if pg_running; then
        echo "postgres already accepting connections host=${DATABASE_HOST:-localhost} port=${DATABASE_PORT:-54320} user=postgres"
      else
        echo "START postgres :: pg_ctl -D ${PGDATA} -l ${PGLOG} -w start (listen_addresses=127.0.0.1, port 54320)"
        if ! pg_ctl -D "${PGDATA}" -l "${PGLOG}" -w start -o "-c listen_addresses=127.0.0.1 -p 54320 -c unix_socket_directories=${SOCKET_DIR}"; then
          echo "--- tail ${PGLOG} ---" >&2
          tail -n 20 "${PGLOG}" 2>/dev/null || true
          echo "ERROR: pg_ctl start failed; see ${PGLOG}" >&2
          exit 1
        fi
      fi
    else
      echo "SKIP local postgres boot :: DATABASE_PORT=${DATABASE_PORT} is provided externally"
    fi

    if wait_for_postgres; then
      exit 0
    fi

    # Failure diagnostics: log tail only in local mode; CI mode exits non-zero
    # with the clear error and never touches local pg_ctl.
    if is_local_postgres; then
      echo "--- tail ${PGLOG} ---" >&2
      tail -n 20 "${PGLOG}" 2>/dev/null || true
    fi
    echo "ERROR: postgres not ready host=${DATABASE_HOST:-localhost} port=${DATABASE_PORT:-54320} user=postgres" >&2
    exit 1
    ;;
  stop)
    if is_local_postgres; then
      require_binaries
      if pg_running; then
        echo "CLEANUP postgres :: pg_ctl -D ${PGDATA} -m fast -w stop"
        pg_ctl -D "${PGDATA}" -m fast -w stop
      else
        echo "postgres not running; nothing to stop"
      fi
    else
      echo "SKIP local postgres stop :: DATABASE_PORT=${DATABASE_PORT} is provided externally"
    fi
    ;;
  status)
    if pg_running; then
      echo "postgres accepting connections host=${DATABASE_HOST:-localhost} port=${DATABASE_PORT:-54320} user=postgres"
      exit 0
    fi
    echo "postgres not ready host=${DATABASE_HOST:-localhost} port=${DATABASE_PORT:-54320} user=postgres" >&2
    exit 1
    ;;
  *)
    echo "Usage: $0 {start|stop|status}" >&2
    exit 64
    ;;
esac
