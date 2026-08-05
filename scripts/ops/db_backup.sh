#!/usr/bin/env bash
# db_backup.sh — logical PostgreSQL backup (custom format) for Hiraeth.
#
# Mirrors docs/production-operations.md "Backup": pg_dump --format=custom
# --no-owner --no-privileges to a timestamped dump file, then verifies the
# dump exists and is non-empty (test -s).
#
# Usage:
#   scripts/ops/db_backup.sh
#   DATABASE_URL=postgres://user:pass@host:5432/db scripts/ops/db_backup.sh
#
# Env:
#   DATABASE_URL  full connection URL (overrides the individual vars below)
#   PGHOST        default 127.0.0.1 (devenv Postgres)
#   PGPORT        default 54320
#   PGUSER        default postgres
#   PGPASSWORD    default postgres
#   DB_NAME       default hiraeth_dev
#   BACKUP_DIR    default backups
#   BACKUP_FILE   explicit output path (default backups/hiraeth-<UTC ts>.dump)
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-backups}"
mkdir -p "$BACKUP_DIR"

# --- Resolve the target database -------------------------------------------
if [[ -n "${DATABASE_URL:-}" ]]; then
  DB_URL="$DATABASE_URL"
else
  PGHOST="${PGHOST:-127.0.0.1}"
  PGPORT="${PGPORT:-54320}"
  PGUSER="${PGUSER:-postgres}"
  PGPASSWORD="${PGPASSWORD:-postgres}"
  DB_NAME="${DB_NAME:-hiraeth_dev}"
  DB_URL="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DB_NAME}"
fi

BACKUP_FILE="${BACKUP_FILE:-$BACKUP_DIR/hiraeth-$(date -u +%Y%m%dT%H%M%SZ).dump}"

# Redact credentials for logging: postgres://user:pass@host -> postgres://user:***@host
redacted_url() {
  sed -E 's#(postgres(ql)?://[^:]+:)[^@]+@#\1***@#'
}

echo "backup_target=$(printf '%s' "$DB_URL" | redacted_url)"
echo "backup_file=$BACKUP_FILE"

pg_dump "$DB_URL" \
  --format=custom \
  --no-owner \
  --no-privileges \
  --file "$BACKUP_FILE"

# Verify the dump exists and is non-empty (docs/production-operations.md).
test -s "$BACKUP_FILE"

echo "backup_bytes=$(stat -c %s "$BACKUP_FILE")"
echo "backup=pass"
