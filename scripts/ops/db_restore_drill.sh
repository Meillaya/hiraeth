#!/usr/bin/env bash
# db_restore_drill.sh — restore a Hiraeth backup into a NEW/replacement database.
#
# Mirrors docs/production-operations.md "Restore": createdb + pg_restore
# --clean --if-exists --no-owner --no-privileges. This drill NEVER touches a
# live database and refuses to run against a non-loopback (prod) host unless
# --force is passed.
#
# Usage:
#   scripts/ops/db_restore_drill.sh [--force] [BACKUP_FILE]
#
# Env:
#   DATABASE_URL            full connection URL (overrides the individual vars)
#   RESTORE_DATABASE_NAME   target DB name (default: hiraeth_restore)
#   BACKUP_FILE             dump to restore (default: newest backups/hiraeth-*.dump)
#   PGHOST/PGPORT/PGUSER/PGPASSWORD  individual connection overrides
set -euo pipefail

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
  shift
fi

BACKUP_FILE="${BACKUP_FILE:-${1:-}}"
if [[ -z "$BACKUP_FILE" ]]; then
  BACKUP_FILE="$(ls -t backups/hiraeth-*.dump 2>/dev/null | head -n1 || true)"
fi
if [[ -z "$BACKUP_FILE" || ! -f "$BACKUP_FILE" ]]; then
  echo "error: no backup file found; run make db-backup first or pass BACKUP_FILE" >&2
  exit 1
fi

# --- Resolve connection -----------------------------------------------------
if [[ -n "${DATABASE_URL:-}" ]]; then
  DB_URL="$DATABASE_URL"
else
  PGHOST="${PGHOST:-127.0.0.1}"
  PGPORT="${PGPORT:-54320}"
  PGUSER="${PGUSER:-postgres}"
  PGPASSWORD="${PGPASSWORD:-postgres}"
  DB_URL="postgres://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/postgres"
fi

RESTORE_DATABASE_NAME="${RESTORE_DATABASE_NAME:-hiraeth_restore}"

# Swap the database name in a postgres URL (admin ops use the `postgres` DB).
swap_db() {
  local url="$1" db="$2"
  printf '%s' "$url" | sed -E "s#(postgres(ql)?://[^/]+/)[^?]*#\1$db#"
}
ADMIN_URL="$(swap_db "$DB_URL" postgres)"
TARGET_URL="$(swap_db "$DB_URL" "$RESTORE_DATABASE_NAME")"

# --- Guards ----------------------------------------------------------------
LIVE_DBS="hiraeth_dev hiraeth_test postgres"
if [[ " $LIVE_DBS " == *" $RESTORE_DATABASE_NAME "* ]] && [[ "$FORCE" != 1 ]]; then
  echo "error: refusing to restore over live database '$RESTORE_DATABASE_NAME'; pass --force to override" >&2
  exit 1
fi

DB_HOST="$(printf '%s' "$DB_URL" | sed -E 's#^postgres(ql)?://[^@]*@([^:/]+).*#\2#')"
case "$DB_HOST" in
  localhost|127.0.0.1|::1|"")
    ;;
  *)
    if [[ "$FORCE" != 1 ]]; then
      echo "error: refusing to restore against non-loopback host '$DB_HOST' (looks like prod); pass --force to override" >&2
      exit 1
    fi
    ;;
esac

# --- Restore into a NEW/replacement database --------------------------------
# The drill DB is re-runnable: drop any existing drill DB first. The guards
# above guarantee it is never a live database.
if psql "$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname = '$RESTORE_DATABASE_NAME'" | grep -q 1; then
  echo "dropping existing drill database: $RESTORE_DATABASE_NAME"
  dropdb --maintenance-db="$ADMIN_URL" "$RESTORE_DATABASE_NAME"
fi

echo "creating database: $RESTORE_DATABASE_NAME"
createdb --maintenance-db="$ADMIN_URL" "$RESTORE_DATABASE_NAME"

echo "restoring from: $BACKUP_FILE"
pg_restore \
  --dbname "$TARGET_URL" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  "$BACKUP_FILE"

# --- Verify migrations landed in the restored database ----------------------
MIGRATION_COUNT="$(psql "$TARGET_URL" -tAc "SELECT count(*) FROM schema_migrations")"
echo "schema_migrations_count=$MIGRATION_COUNT"
if [[ -z "$MIGRATION_COUNT" || "$MIGRATION_COUNT" == "0" ]]; then
  echo "error: no migrations found in restored database '$RESTORE_DATABASE_NAME'" >&2
  exit 1
fi
echo "restore_drill=pass"
