# Production Operations Runbook

This runbook covers the Phoenix release/container path for Hiraeth production deployments. It assumes PostgreSQL 16, the Scrapling sidecar service, and Phoenix releases built from this repository.

## Required Environment

Set these values in the deployment secret store or container environment before starting the Phoenix release:

| Variable | Required | Purpose | Example |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | yes | Signs and encrypts Phoenix cookies and session data. Generate a unique production value with `mix phx.gen.secret`. | `replace-with-generated-secret-key-base` |
| `DATABASE_URL` | yes | PostgreSQL connection string used by `Hiraeth.Repo`. | `postgres://hiraeth_user:replace-with-database-password@postgres:5432/hiraeth_prod` |
| `PHX_HOST` | yes | Public hostname used for generated HTTPS URLs. | `hiraeth.example.com` |
| `SCRAPLING_SIDECAR_URL` | yes | HTTP URL for the Scrapling sidecar reachable from the Phoenix container. | `http://scrapling-sidecar:8000` |
| `POOL_SIZE` | yes | Ecto connection pool size for each running Phoenix instance. Start at `10`, then tune with database capacity and instance count. | `10` |
| `PHX_SERVER` | yes for releases | Enables the Phoenix web server in releases. | `true` |
| `PORT` | no | HTTP port inside the container. Defaults to `4000` in `config/runtime.exs`. | `4000` |

Do not store real passwords, real `SECRET_KEY_BASE`, or production-only tokens in `.env.example`, docs, or git history.

## Build A Phoenix Release

Run these commands from the repository root in a clean build environment:

```bash
mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The release artifact is written under `_build/prod/rel/hiraeth`. Package that directory into the runtime container image or deployment artifact.

## Start The Container

For a release image that contains `_build/prod/rel/hiraeth`, provide the required environment and start the release with the Phoenix server enabled:

```bash
docker run --rm \
  --name hiraeth \
  --env SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  --env DATABASE_URL="$DATABASE_URL" \
  --env PHX_HOST="$PHX_HOST" \
  --env SCRAPLING_SIDECAR_URL="$SCRAPLING_SIDECAR_URL" \
  --env POOL_SIZE="${POOL_SIZE:-10}" \
  --env PHX_SERVER=true \
  --publish 4000:4000 \
  hiraeth:prod \
  bin/hiraeth start
```

With the included Compose services, the sidecar URL for the Phoenix container is:

```bash
SCRAPLING_SIDECAR_URL=http://scrapling-sidecar:8000
```

Keep PostgreSQL and the Scrapling sidecar on the same container network as Phoenix. The runtime config reads `SCRAPLING_SIDECAR_URL` directly and falls back to `http://localhost:8000` only when the variable is unset, which is not suitable for a multi-container production deployment.

The committed `compose.yaml` keeps `scrapling-sidecar` service-network-only by using Compose `expose` and no sidecar `ports` entry. Do not add a sidecar host port to the default or production Compose path. If a developer needs host access for local debugging, use an uncommitted override that binds only to loopback, for example:

```yaml
# compose.sidecar-local-ports.override.yaml (local debugging only; do not use in production)
services:
  scrapling-sidecar:
    ports:
      - "127.0.0.1:8000:8000"
```

Run that override only when needed with `docker compose -f compose.yaml -f compose.sidecar-local-ports.override.yaml up scrapling-sidecar`.

## Run Migrations

Run database migrations before starting new application instances:

```bash
docker run --rm \
  --env SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  --env DATABASE_URL="$DATABASE_URL" \
  --env PHX_HOST="$PHX_HOST" \
  --env SCRAPLING_SIDECAR_URL="$SCRAPLING_SIDECAR_URL" \
  --env POOL_SIZE="${POOL_SIZE:-10}" \
  hiraeth:prod \
  bin/hiraeth eval "Ecto.Migrator.with_repo(Hiraeth.Repo, &Ecto.Migrator.run(&1, :up, all: true))"
```

For non-container release hosts, run the same release command from `_build/prod/rel/hiraeth`:

```bash
PHX_SERVER=false \
SECRET_KEY_BASE="$SECRET_KEY_BASE" \
DATABASE_URL="$DATABASE_URL" \
PHX_HOST="$PHX_HOST" \
SCRAPLING_SIDECAR_URL="$SCRAPLING_SIDECAR_URL" \
POOL_SIZE="${POOL_SIZE:-10}" \
bin/hiraeth eval "Ecto.Migrator.with_repo(Hiraeth.Repo, &Ecto.Migrator.run(&1, :up, all: true))"
```

## Database Pool Sizing

`POOL_SIZE` is per Phoenix instance. Keep total application connections below the PostgreSQL connection limit:

```bash
total_app_connections=$(( PHOENIX_INSTANCE_COUNT * POOL_SIZE ))
```

Leave capacity for migrations, backups, maintenance shells, and database monitoring connections. Increase `POOL_SIZE` only when observed queue time or request latency shows the application is waiting on database connections.

## Backup

Create logical PostgreSQL backups before migrations and before every release that changes ingestion or catalog persistence:

```bash
mkdir -p backups
BACKUP_FILE="backups/hiraeth-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump "$DATABASE_URL" \
  --format=custom \
  --no-owner \
  --no-privileges \
  --file "$BACKUP_FILE"
```

Verify that the backup file exists and is non-empty:

```bash
test -s "$BACKUP_FILE"
```

Store backups outside the application container and outside the database volume. Retain enough backups to cover the latest successful release, the previous release, and any active import or cover-processing incident window.

## Restore

Restore into a new empty database first. Do not restore over the active production database unless production has already been stopped and the incident commander has approved data replacement.

```bash
RESTORE_DATABASE_NAME="${RESTORE_DATABASE_NAME:-hiraeth_restore}"
RESTORE_DATABASE_URL="${RESTORE_DATABASE_URL:-postgres://hiraeth_user:replace-with-database-password@postgres:5432/$RESTORE_DATABASE_NAME}"
BACKUP_FILE="${BACKUP_FILE:-backups/hiraeth-YYYYMMDDTHHMMSSZ.dump}"

createdb "$RESTORE_DATABASE_NAME"
pg_restore \
  --dbname "$RESTORE_DATABASE_URL" \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  "$BACKUP_FILE"
```

Point a one-off Phoenix release at the restored database and verify migrations:

```bash
DATABASE_URL="$RESTORE_DATABASE_URL" \
SECRET_KEY_BASE="$SECRET_KEY_BASE" \
PHX_HOST="$PHX_HOST" \
SCRAPLING_SIDECAR_URL="$SCRAPLING_SIDECAR_URL" \
POOL_SIZE=2 \
bin/hiraeth eval "Ecto.Migrator.with_repo(Hiraeth.Repo, &Ecto.Migrator.migrations(&1))"
```

After verification, switch production traffic to an application instance configured with the restored `DATABASE_URL`.

## Rollback

Prefer rolling back the application image before rolling back data. Use this order unless the incident is a confirmed destructive data migration:

1. Stop new deploy rollout and keep the current healthy instances serving traffic.
2. Start the previous known-good image with the same `SECRET_KEY_BASE`, `PHX_HOST`, `SCRAPLING_SIDECAR_URL`, and `POOL_SIZE`.
3. Verify the previous image can connect to the current database.
4. Shift traffic back to the previous image.

Container command:

```bash
docker run --rm \
  --name hiraeth-rollback \
  --env SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  --env DATABASE_URL="$DATABASE_URL" \
  --env PHX_HOST="$PHX_HOST" \
  --env SCRAPLING_SIDECAR_URL="$SCRAPLING_SIDECAR_URL" \
  --env POOL_SIZE="${POOL_SIZE:-10}" \
  --env PHX_SERVER=true \
  --publish 4000:4000 \
  hiraeth:previous \
  bin/hiraeth start
```

If a destructive migration or bad import requires data rollback, stop Phoenix writers first, restore the last verified backup into a replacement database, run the restore verification commands, then repoint `DATABASE_URL` to the restored database and start the previous known-good image.

## Ingestion Telemetry and Alert Runbook

Hiraeth emits OTP `:telemetry` events for production ingestion operations. Route these events to the deployment's existing log/metrics collector; do not add paid vendor SDKs inside the application.

| Event | Key measurements | Key metadata | Purpose |
| --- | --- | --- | --- |
| `[:hiraeth, :ingestion, :scheduler, :tick]` | `duration` (milliseconds), `created_count`, `skipped_count` | `tick_at` | Confirms the 15-minute Oban scheduler is planning provider runs. |
| `[:hiraeth, :ingestion, :queue, :latency]` | `duration` (milliseconds) | `worker`, optional safe provider/run/source identifiers | Tracks how long ingestion jobs waited in Oban before execution. |
| `[:hiraeth, :ingestion, :phase, :stop]` | `source_count`, `snapshot_count`, `candidate_count`, `accepted_count`, `rejected_count`, `error_count`, `quarantine_age_seconds` | `provider_run_id`, `provider_source_id`, `phase`, `status`, `error_code` | Tracks provider run phases without exposing source payloads. |
| `[:hiraeth, :ingestion, :sidecar, :error]` | `count` | `operation`, `error_code`, optional safe provider/run/source identifiers | Counts private Scrapling sidecar fetch/scrape/detail failures. |
| `[:hiraeth, :ingestion, :cover, :cache]` | `candidate_count`, `cached_count`, `failed_count`, `error_count` | `status`, `provider_run_id`/`provider_source_id` for candidate cover runs, or `provider` for strict legacy cover cache | Tracks cover candidate and strict legacy cover cache failures. |

Telemetry metadata is intentionally whitelisted by helper APIs and limited to identifiers, phases, statuses, counts, provider labels, and coarse error codes. Do not attach raw source records, URLs, HTML, JSON payloads, sidecar response bodies, database credentials, cookies, or authorization headers to ingestion telemetry.

### Alert Thresholds

Use these initial thresholds and tune after two weeks of normal production traffic:

| Alert | Threshold | Severity | Response |
| --- | --- | --- | --- |
| Scheduler missing or failing | No `scheduler.tick` event for 30 minutes, or two consecutive ticks fail to create/skip summaries | page | Check the Phoenix node, Oban supervision, database readiness, and the Cron plugin config. Run `bin/hiraeth eval "Hiraeth.Ingestion.ProviderScheduler.schedule_tick()"` once only after confirming no active incident command conflict. |
| Scheduler creates zero runs unexpectedly | `created_count == 0` for 4 consecutive ticks while enabled automatic provider sources exist and no active runs are present | ticket | Inspect provider sources for `enabled?`, `source_kind`, and `ingestion_mode`; check active queued/running provider runs that may be stuck. |
| Queue latency high | `queue.latency.duration > 300_000 ms` for ingestion workers for 3 consecutive samples | page during import window, ticket otherwise | Inspect Oban queue depth, DB pool saturation, Repo query queue time, and sidecar availability. Scale workers only after verifying the sidecar and provider rate limits can tolerate more concurrency. |
| Phase failures | Any `phase.stop` with `status == :failed` for `fetch_snapshot`, `normalize_candidates`, `validate_candidates`, `diff_candidates`, `apply_candidates`, `audit_run`, or `provider_ingestion_worker` | page for production providers | Open the provider run timeline, read the matching append-only ingestion event, identify `error_code`, and retry only idempotent phases. Do not force destructive apply; quarantined/removal candidates require review. |
| Sidecar errors | `sidecar.error.count >= 3` for the same `operation`/`error_code` in 15 minutes, or any sustained `rate_limited`, `blocked`, `schema_changed`, `invalid_host`, or `parse_failed` spike | page | Check sidecar health/readiness, private network reachability, provider allowlists, provider HTML/schema changes, and rate-limit settings. For `rate_limited` or `blocked`, pause retries and lower concurrency before resuming. |
| Candidate spike/drop | `candidate_count` changes by more than 50% from the previous successful run for the same provider, or `candidate_count == 0` for a provider expected to have records | ticket, page for launch-critical providers | Compare retained snapshots, provider manifest `expected_record_count`, source checksum, and diff candidates. Treat sudden removals as quarantine/review work, not automatic deletes. |
| Quarantine stale age | `quarantine_age_seconds > 86_400` for normal providers or `> 3_600` for launch-critical ingestion drills | ticket | Review quarantined candidates in the operator console, resolve validation findings, approve safe non-destructive candidates, or leave destructive/removal candidates quarantined with an operator note. |
| Cover failures | `cover.cache.failed_count > 0` for two consecutive runs or `cover.cache.error_count >= 5` in 30 minutes | ticket | Verify cover host allowlists, HTTPS availability, byte-size limits, thumbnail generation, and local cache disk permissions. Public UI must keep rendering local cached covers or typographic fallbacks; never hotlink remote covers as a workaround. |

### Incident Response Steps

1. **Identify scope.** Capture the affected `provider_run_id`, `provider_source_id`, phase, status, and `error_code` from telemetry and the matching `ingestion_events` row.
2. **Check service health.** Verify `/health`, `/ready`, database connectivity, Oban queue depth, and the private Scrapling sidecar health endpoint from the Phoenix runtime network.
3. **Preserve evidence.** Keep retained source snapshots, candidate rows, ingestion events, and cover candidate state. Do not delete failed runs while diagnosing.
4. **Prevent unsafe writes.** Do not bypass quarantine, tombstone, or replay safeguards. Do not run destructive catalog changes from ad-hoc SQL.
5. **Retry safely.** Retry idempotent fetch/normalize/validate/diff work only after sidecar and provider conditions are understood. For rate limits, wait for the provider window to reset and reduce concurrency.
6. **Resolve stale quarantine.** Review validation findings and candidate diffs, approve only source-backed non-destructive records, and document rejected or deferred candidates in reviewer notes.
7. **Resolve cover incidents.** Fix allowlists, cache root permissions, max-byte limits, or thumbnailer failures; rerun cover cache work after confirming public pages still avoid remote image URLs.
8. **Close out.** Record the root cause, affected provider runs, operator actions, and any threshold tuning in release/operations notes.

### Dashboard Panels

Build operator dashboards from the telemetry events above:

- Scheduler tick freshness, created/skipped counts, and last tick timestamp.
- Oban ingestion queue latency p50/p95/max by worker.
- Provider phase success/failure counts by phase and provider run.
- Sidecar error rate by operation and error code.
- Candidate count trend by provider run, including accepted/rejected/error counts.
- Maximum quarantine age and current stale-quarantine count.
- Cover cache cached/failed/error counts and latest failed provider run.

All panels should link back to provider run IDs or operator-console run timelines rather than exposing raw source payloads.
