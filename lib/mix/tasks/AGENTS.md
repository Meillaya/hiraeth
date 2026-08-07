# OPERATOR MIX TASKS KNOWLEDGE BASE

## OVERVIEW
Nine `Mix.Tasks` modules under `lib/mix/tasks/` that wrap Ash domains and the Scrapling sidecar for operator-driven catalog work. Tasks are thin CLI shells: parsing, app boot, sidecar health, JSON/dry-run plumbing, and exit codes. No domain logic lives here; every behavior delegates to `lib/hiraeth/*` or `sidecar/app`. Inherits repo-wide rules from `../../AGENTS.md` and domain rules from `../hiraeth/AGENTS.md`; do not duplicate them.

## STRUCTURE
| Task | Module | Primary domain target |
|---|---|---|
| `mix hiraeth.apply_scrape` | `Mix.Tasks.Hiraeth.ApplyScrape` | `Hiraeth.Ingestion` + `Hiraeth.RealCatalog.Importer` (apply staged dataset) |
| `mix hiraeth.audit_provenance` | `Mix.Tasks.Hiraeth.AuditProvenance` | `Hiraeth.ProvenanceAudit` (seed/run/export) |
| `mix hiraeth.cache_covers` | `Mix.Tasks.Hiraeth.CacheCovers` | `Hiraeth.Covers.cache_public_covers!/1` |
| `mix hiraeth.ingest` | `Mix.Tasks.Hiraeth.Ingest` | delegates `do_run/1` to `Hiraeth.Ingestion.OperatorCLI.run_args/1` |
| `mix hiraeth.providers.backfill` | `Mix.Tasks.Hiraeth.Providers.Backfill` | `Hiraeth.Sources` (provider plan + record backfill) |
| `mix hiraeth.real_catalog.coverage_report` | `Mix.Tasks.Hiraeth.RealCatalog.CoverageReport` | `Hiraeth.RealCatalog` coverage/cap report |
| `mix hiraeth.real_catalog.source_artifacts` | `Mix.Tasks.Hiraeth.RealCatalog.SourceArtifacts` | `Hiraeth.RealCatalog.SourceArtifacts` (artifact audit/export) |
| `mix hiraeth.review_scrape` | `Mix.Tasks.Hiraeth.ReviewScrape` | `Hiraeth.Ingestion` (review/approve staged dataset) |
| `mix hiraeth.scrape` | `Mix.Tasks.Hiraeth.Scrape` | `Hiraeth.Ingestion.ProviderManifest`, `SidecarClient`, `RealCatalog.{Dataset,SourcePolicy,Validator}` |

## WHERE TO LOOK
| Need | Look here |
|---|---|
| Task usage/flags | per-file `@moduledoc` (do not duplicate in this AGENTS) |
| Operator CLI argument parser, dry-run, JSON, cancel/replay | `Hiraeth.Ingestion.OperatorCLI`, `Hiraeth.Ingestion.OperatorDryRun`, `Hiraeth.Ingestion.OperatorControl`, `Hiraeth.Ingestion.OperatorJSON` |
| Default provider manifest path / staged dataset path | `Hiraeth.Ingestion.ProviderManifest.default_dir/0` and `Application.app_dir(:hiraeth, "priv/catalog_sources/...")` |
| Sidecar boundary + health/contract posture | `Hiraeth.Ingestion.SidecarClient` and `../../sidecar/AGENTS.md` |
| Cover cache write/read safety | `Hiraeth.Covers`, `priv/static/covers` sandbox contract (root AGENTS) |
| Mock swap pattern for tests | `test/support/ingestion/mix_task_mocks/` (`Hiraeth.TestSupport.MixTaskMocks.*`) |
| Task seam tests | `test/hiraeth/ingestion/mix_task_test.exs`, `mix_task_dry_run_test.exs`, `mix_task_control_test.exs` |

## CONVENTIONS
- Module shape: `use Mix.Task`, `@shortdoc "..."`, and a usage `@moduledoc` describing the flags (flags live in `@moduledoc`, not here).
- First executable line of `run/1` is always `Mix.Task.run("app.start")`.
- Parse with `OptionParser.parse(args, strict: [...])`; never `switches`/loose parsing.
- All non-zero exits use `exit({:shutdown, 1})` after writing through `Mix.shell().error/1`; helper `format_error_message/1` accepts binary or arbitrary terms.
- Expose `@doc false def do_run(args)` as the test seam so suites call it without booting Mix. `run/1` wraps `do_run/1` with the error/exit shell.
- `--json` output goes through `Hiraeth.Ingestion.OperatorJSON.print/2` (or the task-local equivalent); do not hand-roll `Jason.encode!` for ingest-shaped payloads.
- `--dry-run` must never persist Ash writes, sidecar staging, or cover cache files. The invariant is locked by `test/hiraeth/ingestion/mix_task_dry_run_test.exs`.
- `--wait` polls the Oban run state via the shared Operator control path; do not duplicate polling logic per task.
- Sidecar health-check error string must point operators to the devenv-managed `scrapling-sidecar` process and to `SCRAPLING_SIDECAR_URL`; the production boundary (Railway + root/sidecar Dockerfiles) is referenced instead of any local orchestration fallback.
- Paths under `priv/` resolve through `Application.app_dir(:hiraeth, "priv/catalog_sources/...")`; do not hardcode repo-relative paths for staged datasets or manifest defaults.
- Keep tasks free of business rules: dispatch to Ash actions, ingestion phases, the Operator CLI, or `Hiraeth.Covers`. Hard-coded provider lists, URL allowlists, or normalization belong in domains.
- Test seam: `Hiraeth.DataCase, async: false` with sidecar/importer/cover-pipeline swap via `Hiraeth.TestSupport.MixTaskMocks.*` modules registered through `:hiraeth, :sidecar_client` / `:importer` / `:cover_pipeline` config. See `../test/AGENTS.md` for the cost-tag taxonomy that bounds these suites.

## ANTI-PATTERNS
- Putting ingestion, normalization, validation, or cover policy logic inside a Mix task instead of delegating to `Hiraeth.Ingestion`, `Hiraeth.RealCatalog`, or `Hiraeth.Covers`.
- Persisting Ash rows, staged datasets, cover cache files, or Oban enqueues while `--dry-run` is set.
- Bypassing `OperatorCLI` from `mix hiraeth.ingest` or duplicating its argument schema in the task module.
- Hand-rolling JSON output instead of routing through `OperatorJSON` / `Hiraeth.Ingestion.OperatorJSON.print/2`.
- Hard-coded provider manifests, source hosts, cover hosts, or rate limits inside task code (use `priv/catalog_sources/provider_manifests/<slug>.json`).
- Adding HTTP/network calls from the task directly; the only network boundary is the private sidecar client.
- Reimplementing the sidecar health error message without the devenv + `SCRAPLING_SIDECAR_URL` pointer, or silently swallowing the failure as `:ok`.
- Reaching into `priv/static/covers/cache/*` from a task or test; cover writes go through `Hiraeth.Covers` and obey the root sandbox contract.
