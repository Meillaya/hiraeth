# Production Operations Runbook

This runbook covers the Phoenix release/container path for Hiraeth production deployments. It assumes PostgreSQL 16, the Scrapling sidecar service, and Phoenix releases built from this repository.

Local development has a bounded partial migration to devenv: devenv is the preferred local/dev/test path for shell work, managed loopback PostgreSQL/Phoenix/sidecar processes, and readiness tasks. Local development is devenv-only. Docker remains the current production runtime boundary reference: Railway builds the Phoenix service from the root `Dockerfile` and the sidecar from `sidecar/Dockerfile`. Do not use this runbook to claim that production is Nix/devenv-only.

## Production Runtime Boundary

The Docker-to-devenv migration is a bounded local/dev/CI-build migration, not in every capacity, and it is not a production migration. devenv is the preferred path for local shell work, local managed PostgreSQL/Phoenix/sidecar processes, and CI-build verification covered by the migration plan. For this boundary, production orchestration remains Docker/Dockerfile-based (Railway) or future-runtime scoped until a separate production-runtime plan is approved and verified.

Docker remains the current production runtime boundary reference. Do not describe Hiraeth production as Docker-free, Nix/devenv-only, or fully migrated away from Docker. The production runtime target is Railway (managed platform). The following production runtime decisions are resolved for Railway:

- **orchestration target**: Railway managed platform. One Railway project with a production environment containing three services: a managed PostgreSQL 16 database (Railway Postgres template), the Phoenix service (builds from the committed root `Dockerfile`), and the private Scrapling sidecar service (builds from `sidecar/Dockerfile`). The Phoenix service reads `DATABASE_URL=${{Postgres.DATABASE_URL}}` as a Railway reference variable, which also orders deploys so Postgres deploys before Phoenix.
- **sidecar private network**: Railway private networking. Phoenix reaches the sidecar over the private network at `http://sidecar.railway.internal:8000` (internal DNS, zero-config, Wireguard-encrypted, no public exposure). The sidecar gets no public domain and no public port; set `SCRAPLING_SIDECAR_URL=http://sidecar.railway.internal:8000`. CORS/private-host safeguards are preserved: `HIRAETH_SIDECAR_CORS_ORIGINS` stays unset in production (server-to-server calls need no CORS), and the sidecar's URL validation still rejects private, loopback, link-local, and userinfo fetch targets.
- **backup/restore tooling**: logical PostgreSQL backups via `scripts/ops/db_backup.sh` and `scripts/ops/db_restore_drill.sh` (pg_dump `--format=custom` plus a pg_restore drill into a scratch database) remain the portable, offsite layer and the only layer that survives project deletion. Railway's managed Postgres adds scheduled volume backups (daily kept 6 days, weekly 1 month, monthly 3 months) and point-in-time recovery (pgBackRest, roughly a 4-week window) for same-project restore. Run the restore drill on a schedule and record restore time and dump age as the real RTO/RPO.
- **memory limits**: Railway has no instance size to pick; services scale vertically up to plan limits and are billed per minute of actual usage (RAM $10/GB/month, CPU $20/vCPU/month). Translate the standing sidecar 2 GB memory assumption and the Phoenix/PostgreSQL capacity assumptions into per-service replica limits (service settings → Deploy → Replica Limits) set at 1.5-2x the observed peak from the Metrics tab: sidecar 2 GB, Phoenix 1 GB to start, tuned from metrics. `POOL_SIZE` stays per-instance (start at 10); keep `instances × POOL_SIZE` below the Postgres connection limit.
- **logs/observability**: Railway logs (build/deploy panel, Log Explorer, `railway logs` CLI) are the collector. The prod `logger_json` structured JSON logs make Phoenix/Oban logs filterable in the Log Explorer (`@level:error`, `@requestId:...`); Postgres and sidecar logs land in the same environment Log Explorer. The ingestion `:telemetry` events and alert thresholds below stay as documented; no unapproved vendor SDKs are added.
- **rollout/rollback**: Railway deploys. A pre-deploy command runs migrations (`bin/hiraeth eval "Ecto.Migrator.with_repo(Hiraeth.Repo, &Ecto.Migrator.run(&1, :up, all: true))"`) before the new version goes live; a failed pre-deploy aborts the deploy. The Railway healthcheck polls `/health` (excluded from `force_ssl`) until HTTP 200 before switching traffic (default 300s timeout). Rollback is a Railway deployment rollback (three-dot menu on a prior deployment), which restores the previous image and variables; image retention bounds how far back rollback works (Hobby 72h, Pro 120h). Database restore uses the drill scripts (logical) or a Railway volume-backup/PITR restore into a replacement database, then repoints `DATABASE_URL`.

## Required Environment

Set these values in the deployment secret store or container environment before starting the Phoenix release:

| Variable | Required | Purpose | Example |
| --- | --- | --- | --- |
| `SECRET_KEY_BASE` | yes | Signs and encrypts Phoenix cookies and session data. Generate a unique production value with `mix phx.gen.secret`. | `replace-with-generated-secret-key-base` |
| `DATABASE_URL` | yes | PostgreSQL connection string used by `Hiraeth.Repo`. | `postgres://hiraeth_user:replace-with-database-password@postgres:5432/hiraeth_prod` |
| `PHX_HOST` | yes | Public hostname used for generated HTTPS URLs. | `hiraeth.example.com` |
| `SCRAPLING_SIDECAR_URL` | yes | HTTP URL for the Scrapling sidecar reachable from the Phoenix service. | `http://sidecar.railway.internal:8000` |
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

On Railway, Phoenix reaches the sidecar over the private network:

```bash
SCRAPLING_SIDECAR_URL=http://sidecar.railway.internal:8000
```

Keep PostgreSQL and the Scrapling sidecar private to the deployment network. The runtime config reads `SCRAPLING_SIDECAR_URL` directly and falls back to `http://localhost:8000` only when the variable is unset, which is not suitable for production. The sidecar must never get a public domain or host port; local debugging binds loopback only (`127.0.0.1:8000`) through devenv, as documented in `sidecar/README.md`.

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
| Quarantine stale age | `quarantine_age_seconds > 86_400` for normal providers or `> 3_600` for launch-critical ingestion drills | ticket | Review quarantined candidates via the `mix hiraeth.ingest` CLI output and the DB ingestion tables (record candidates and diffs), resolve validation findings, approve safe non-destructive candidates, or leave destructive/removal candidates quarantined with an operator note. The "Autonomous catalog updates" runbook section covers the full review workflow. |
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

All panels should link back to provider run IDs or ingestion run timelines rather than exposing raw source payloads.

## Autonomous catalog updates

Scheduled ingestion runs without an operator: the Oban Cron plugin ticks the scheduler, the scheduler plans and dispatches provider runs, and the worker pipeline applies only quarantine-clear, non-destructive changes. This section covers what runs when, the non-destructive guarantee, enabling/disabling autonomy, rollout order, and investigation paths.

### What runs when

All autonomous scheduling comes from the Oban Cron crontab built in `config/runtime.exs` (UTC):

| Schedule (UTC) | Worker | Queue | What it does |
| --- | --- | --- | --- |
| Every 15 minutes (`*/15 * * * *`) | `Hiraeth.Oban.ProviderSchedulerWorker` | `ingestion` | Scheduler tick: plans and dispatches due provider runs. |
| Sunday 04:00 (`0 4 * * 0`) | `Hiraeth.Oban.CoverRefreshWorker` | `covers` | Weekly cover cache refresh (mix-task-identical defaults: `force?: false`, `strict?: false`). |
| Sunday 04:30 (`30 4 * * 0`) | `Hiraeth.Oban.ProvenanceAuditWorker` | `audit` | Weekly provenance audit export to `artifacts/qa/provenance`. |

Each scheduler tick (`Hiraeth.Ingestion.ProviderScheduler.schedule_tick/1`):

- Classifies enabled manifest-mode provider sources against their per-provider `cadence_hours` (default `24`, overridable per provider in the provider manifest) using the last-succeeded `finished_at` of the previous run; sources past their cadence are due.
- Creates a new queued `ProviderRun` (`run_key` `"scheduled:<iso8601>"`) for due sources with no pending scheduled run, or **adopts** an existing queued scheduled run (`status = 'queued'` and `requested_by = 'provider_scheduler'`) so a stale queued run from a previous tick is consumed instead of duplicated.
- Dispatches at most **2 runs per tick**, ordered oldest-last-succeeded first; sources beyond the cap are deferred (`dispatch_cap_deferred` skip reason) to the next tick.
- Emits telemetry: `[:hiraeth, :ingestion, :scheduler, :tick]` (created/skipped counts, `tick_at`), `[:hiraeth, :ingestion, :scheduler, :dispatch, :start]` and `[:hiraeth, :ingestion, :scheduler, :dispatch, :stop]` (`tick_at`, `dispatched_count`).

The weekly workers emit their own telemetry events: `[:hiraeth, :covers, :scheduled, :refresh]` (cover refresh) and `[:hiraeth, :provenance, :scheduled, :audit]` (provenance audit).

### Non-destructive guarantee

Scheduled runs can only ever **add or update** catalog data; they can never remove it:

- In the worker pipeline, the scheduled path (job arg `"scheduled" => true`) auto-approves candidates that are simultaneously `diff_classification` in `[new, changed, unchanged]`, `quarantine_status` `"clear"`, and `review_decision` `"pending_review"` — via the `approve_for_apply` action with `review_actor_id` `"provider_scheduler"`.
- `removed`, `invalid`, and `destructive` candidates are force-quarantined at creation and never match that filter, so a scheduled run can **never tombstone** a catalog row. Tombstoning stays a reviewed, operator-only action.
- The auto-approval is idempotent by construction: approved candidates leave `pending_review`, so re-running a tick or replaying a snapshot cannot double-approve.
- Operator runs (`mix hiraeth.ingest`, `requested_by = 'mix hiraeth.ingest'`) never get the `"scheduled"` flag, so the manual lane keeps its full review gates.

### Pre-rollout reconciliation (mandatory)

Before enabling autonomy on Railway (`HIRAETH_SCHEDULED_INGEST=true`), reconcile the queued runs the old eager scheduler left behind. On the production database:

```sql
SELECT count(*), provider_source_id
FROM provider_runs
WHERE status = 'queued' AND requested_by = 'provider_scheduler'
GROUP BY provider_source_id;
```

- Expect roughly **11 stale queued scheduled runs** from the pre-dispatcher scheduler. This is plausible, not an incident.
- The adoption rule consumes them at 2 per tick, so they drain over ~90 minutes after autonomy is enabled. No action is needed beyond confirming the per-provider counts are plausible (one run per provider) and that none are weeks-stale duplicates.
- If any provider has **more than one** stale queued run, cancel the duplicates (keep one) before enabling autonomy.

### Kill-switch

- Set `HIRAETH_SCHEDULED_INGEST=false` in the Railway dashboard (Variables tab) and redeploy. `config/runtime.exs` then builds the Oban plugin list without the Cron entries, so **all three autonomous schedules are off**: the 15-minute tick, the weekly cover refresh, and the weekly provenance audit. Queues and the Pruner remain.
- Manual operator tasks (`mix hiraeth.ingest ...`, `mix hiraeth.cache_covers`, `mix hiraeth.audit_provenance`) are unaffected by the kill-switch.
- The default when the variable is unset is `true` (autonomy on). Local development via devenv pins `HIRAETH_SCHEDULED_INGEST=false`, so there is **no local auto-fetch**; run providers explicitly with `mix hiraeth.ingest --provider <slug> --wait`.

### Rollout order for the migrations

Two migrations in this area have ordering constraints relative to the code that uses them:

1. **Apply `20260806002149_add_provider_sources_cadence_hours` in production BEFORE deploying any release whose code declares `cadence_hours`.** AshPostgres selects every declared attribute, so code that declares the attribute against a table that lacks the column fails at query time. The migration is a safe additive `ALTER TABLE ... ADD COLUMN` with `NOT NULL DEFAULT 24`.
2. **Apply `20260806001818_drop_imports_csv_workflow_tables` only AFTER the release that removed the Imports CSV resources is live.** The migration drops `review_items`, `staged_import_rows`, and `import_mappings` (not `import_runs`, which keeps live provenance lineage). Running the drops against code that still references the resources breaks those queries.

Railway runs migrations via the release pre-deploy command before switching traffic, so the ordering rule above means: deploy the migration ahead of the attribute-declaring code (or include the cadence migration in the deploy immediately before), and never let the drop migration run before the removal code is live.

### Railway single-instance notes

- The Phoenix web server and Oban run in the **same container** (one Railway service). Oban workers share the web process's BEAM node.
- A Railway deploy (including an env-var change with redeploy) interrupts executing jobs; Oban's default retry behavior re-runs interrupted jobs after the new version boots.
- Environment variables — including `HIRAETH_SCHEDULED_INGEST` — are dashboard config; changing them requires a redeploy to take effect.

### Investigating scheduled runs

- **Oban job states**: query `oban_jobs` for the workers above (`worker` in `Hiraeth.Oban.ProviderSchedulerWorker`, `Hiraeth.Oban.ProviderIngestionWorker`, `Hiraeth.Oban.CoverRefreshWorker`, `Hiraeth.Oban.ProvenanceAuditWorker`) and inspect `state` (`available`, `scheduled`, `executing`, `retryable`, `completed`, `discarded`, `cancelled`) and `args`.
- **IngestionEvent kinds**: `phase_enqueue_intent` (a run was planned/dispatched), `dispatch_skipped_job_pending` (dispatch skipped because a unique job is already pending for that provider — the run stays queued and is adopted later), plus the `scheduler.dispatch` start/stop telemetry events.
- **ProviderRun statuses**: `queued` → `running` → `succeeded`/`failed`; scheduled runs carry `run_key` `"scheduled:<iso8601>"` and `requested_by` `"provider_scheduler"`. A long-lived `queued`/`running` scheduled run blocks re-dispatch for that provider (skip reason `active_run_exists`).
- **Quarantine review**: `mix hiraeth.ingest` output and the DB ingestion tables (record candidates and diffs) show what is quarantined and why. Approve only source-backed non-destructive candidates; leave `removed`/`invalid`/`destructive` quarantined with an operator note. See the alert response steps above for the full workflow.
- **Force a provider now**: `mix hiraeth.ingest --provider <slug> --wait` runs the full pipeline synchronously as a manual operator run, bypassing cadence and the dispatch cap.
