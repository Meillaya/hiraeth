# INGESTION WORKFLOW KNOWLEDGE BASE

## OVERVIEW
Phase workflow boundary for provider ingestion. Parent knowledge bases govern domain ownership and shared policy. This file owns phase order, context handoff, run completion, operator lanes, and focused tests.

## STRUCTURE
| Area | Owns |
|---|---|
| `phases/` | fetch, normalize, validate, diff, quarantine, apply, tombstone, audit, replay, run state |
| `operator_*.ex` | `mix hiraeth.ingest` setup, dry run, cancel, replay, wait, JSON output |
| `provider_scheduler.ex` | cron tick planning and phase enqueue intent |
| `provider_backfill.ex`, `provider_backfill/` | deterministic `ProviderSource` inventory reconciliation |
| `cover_*.ex` | candidate cover compatibility, cache root guard, per-run cover results |
| `provider_manifest.ex`, `manifest_validator.ex` | manifest loading and source-host checks |
| `provider_record_normalizer.ex` | raw-record normalization rules used by the pipeline |
| `sidecar_client.ex` | typed fetch, scrape, normalize, health contract |
| `telemetry.ex` | fixed ingestion events, measurements, and metadata allowlists |

## WHERE TO LOOK
| Task | File |
|---|---|
| Worker orchestration | `lib/hiraeth/oban/provider_ingestion_worker.ex` |
| Phase transition/status rules | `phases/run_state.ex` |
| Candidate classification | `phases/diff_candidates.ex`, `record_candidate.ex` |
| Quarantine and apply gates | `phases/quarantine_run.ex`, `phases/apply_candidates.ex` |
| Approved removals | `phases/tombstone_candidates.ex` |
| Snapshot replay | `phases/replay_snapshot.ex`, `source_snapshot/` |
| Autonomous operator lane | `operator_cli.ex`, `mix hiraeth.ingest` |
| Scheduler cron lane | `provider_scheduler.ex`, `Hiraeth.Oban.ProviderSchedulerWorker` |
| Registry backfill lane | `provider_backfill.ex`, `mix hiraeth.providers.backfill` |
| Staged-scrape lane | `mix hiraeth.scrape`, `mix hiraeth.review_scrape`, `mix hiraeth.apply_scrape` |
| Local phase/apply tests | `phase_workers`, `apply_phase`, `apply_phase_regression`, `replay_phase_regression` |
| Local control/diff tests | `control_plane_resources`, `record_candidate_diff` |
| Local cover tests | `cover_pipeline`, `cover_candidate`, `cover_cache_root` |
| Local boundary tests | `sidecar_contract`, `sidecar_client`, `telemetry`, `e2e_ingestion` |

## AUTHORITATIVE WORKER PHASE ORDER
`Hiraeth.Oban.ProviderIngestionWorker` threads one ordered, map-shaped context through every row.

| Order | Phase | Context/result contract |
|---|---|---|
| 1 | `FetchSnapshot` | load manifest and policy; fetch; retain snapshot; add manifest, source/run IDs, snapshot, mode, raw records |
| 2 | `NormalizeCandidates` | consume raw records; add normalized records |
| 3 | `ValidateCandidates` | validate count and dataset; add replayable dataset and checksum |
| 4 | `DiffCandidates` | persist new/changed/unchanged/removed candidates; add candidates and count |
| 5 | cover compatibility step | cache dataset covers via `CoverCandidateRun`; preserve context; fail worker phase on cache error |
| 6 | `QuarantineRun` | summarize blocked candidates; add quarantined candidates |
| 7 | `ApplyCandidates` | run nested `TombstoneCandidates`; apply only approved, clear, non-destructive candidates; add apply/tombstone summaries |
| 8 | `AuditRun` | run provider provenance audit; add audit result |
| 9 | worker finish marker | mark `:provider_ingestion_worker` succeeded; return provider/count/mode summary |

## CONVENTIONS
- Preserve phase order and return `{:ok, context}` with prior keys intact; downstream pattern matches are the contract.
- Only the worker finish marker changes a run to `succeeded`; successful intermediate phases leave it `running`.
- Check cancellation before each phase and finish. Cancellation is sticky and later progress can't revive the run.
- Default removed, invalid, and destructive candidates to quarantine. Apply requires explicit approval plus clear quarantine state.
- Removal approval records append-only tombstone provenance. It never deletes catalog rows.
- Treat source records, snapshot rows, and retained artifacts as immutable evidence; append or replay instead of rewriting.
- Require manifest source URLs, API endpoints, and scrape start URLs to match the normalized `source_hosts` allowlist.
- Keep telemetry to declared event fields, counts, identifiers, statuses, phase names, and coarse error codes. Fixed events: phase.stop, scheduler.tick, scheduler.dispatch.{start,stop} (tick_at + dispatched_count), sidecar.error, queue.latency, cover.cache — sanitize allowlists live in `telemetry.ex`.
- Keep lanes separate: ingestion creates candidate runs; scheduler plans cron runs; backfill reconciles provider registry; scrape/review/apply manages checked-in staged datasets.
- Oban queues are `ingestion: 4`, `covers: 4`, `audit: 2`; `ProviderSchedulerWorker` runs on cron `*/15 * * * *`; tests use `Oban testing: :manual`.

## ANTI-PATTERNS
- Reordering phases, skipping quarantine, or calling `TombstoneCandidates` outside `ApplyCandidates`.
- Replacing the phase context with positional tuples, lists, or a partial map.
- Marking a run succeeded from fetch, apply, audit, scheduler, or an Oban job state.
- Clearing cancellation, auto-approving removals, or applying invalid/destructive candidates.
- Mutating source/snapshot evidence or overwriting retained artifacts during replay.
- Fetching a host absent from the manifest allowlist or emitting payloads, URLs, credentials, or response bodies in telemetry.
- Treating staged scrape tasks as aliases for the candidate-based autonomous pipeline.
