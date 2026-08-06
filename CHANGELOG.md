# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Self-hosted OFL fonts (Newsreader, Space Grotesk, Space Mono) with `@font-face` rules and license/provenance documentation under `priv/static/fonts/`.
- Three full-site design prototypes built from real catalog data under `artifacts/design-prototypes/` as the sanctioned UI exploration artifact; `docs/architecture.md` documents the fallback when the `agy` CLI produces no output.
- Per-provider `cadence_hours` on provider manifests and `ProviderSource` (default 24h) with manifest validation and backfill.
- Weekly scheduled cover cache refresh and provenance audit workers on the idle `:covers` and `:audit` Oban queues.
- README pointer to the "Autonomous catalog updates" ops runbook section for what runs when, the kill-switch, and rollout order.

### Changed

- CI consolidated: the deep lane runs the full suite once with coverage merged into a single coveralls run (86.1 floor); the `devenv-smoke` job stays as PR-time proof of the pinned Nix BEAM toolchain.
- Mix aliases collapsed to `gate` (single fast blocking gate), `ci` (full lane), `test.fast`, and `test.full`; the Makefile `verify` chain slimmed to `audit-provenance test-browser verify-summary qa-pack`.
- Local development is devenv-only; the root and `sidecar/Dockerfile` remain the production runtime boundary.
- Sidecar `base_url` config de-duplicated: the default lives in `config/config.exs`, dev/test inherit it, and `config/runtime.exs` reads `SCRAPLING_SIDECAR_URL`.

### Removed

- Unrouted page scaffold, Swoosh/Mailer, and the dev-only mailbox route.
- `Hiraeth.Search` domain, the Imports CSV workflow (including its tables via a drop migration), and the never-enqueued `SourceSnapshotReplayWorker`.
- `compose.yaml` and every Compose reference; devenv owns local, Dockerfiles own production.

## [1.0.0] - 2026-08-05

### Added

- Tiered verification gates: fast local blocking gate (`mix gate`), parallel CI static + fast-test jobs, and a deep verification lane (dialyzer, coverage, full suite, browser QA, ingestion drills, sidecar pytest, release image builds).
- Static analysis and coverage tooling: Credo strict, Dialyzer (with persisted PLT), Sobelow, ExCoveralls with a coverage floor, and `mix quality` / `mix ci` aliases.
- Dependency security gates: `hex.audit` in CI and `uv audit` for the sidecar; patched vulnerable Elixir dependencies.
- Python quality gates for the sidecar: ruff (lint + format), pyright basic check, and wiring of the orphaned `tests/scripts` suite into CI.
- Root `.editorconfig` covering Elixir, Python, shell, JS, YAML, and JSON.
- Production runtime hardening: `config/runtime.exs` requires `PHX_HOST`, `SCRAPLING_SIDECAR_URL`, and `LIVE_VIEW_SIGNING_SALT` in prod, with JSON logging via `logger_json` and a validated `LOG_LEVEL`.
- Secure session cookies (`secure` flag + `encryption_salt`) and a compile-time gate that drops the RequestLogger plug in prod.
- `/health` excluded from `force_ssl` and a prod `require_sidecar` readiness flag so Railway healthchecks pass while `/ready` stays the operator probe.
- Content-Security-Policy on the `:browser` pipeline (self-contained page contract, no remote resources).
- Release artifacts: explicit `releases` config in `mix.exs`, a root multi-stage Dockerfile, a hardened sidecar Dockerfile (pinned base, non-root user, healthcheck, no dev extras), and a CI `release-build` gate.
- Ops tooling: `scripts/ops/db_backup.sh` and `scripts/ops/db_restore_drill.sh` with Makefile targets and live-DB/prod-URL guards.
- `.env.example` completed with required/optional markers and a parity contract test that derives the required set from `config/runtime.exs`.

### Changed

- `config/runtime.exs` prod branch now raises on missing required environment variables instead of silently defaulting.
- Sidecar `httpx` moved from dev extras to runtime dependencies so the hardened image boots; `apify_fingerprint_datapoints` pinned to keep browser fingerprint data compatible with the base image's Scrapling.
- Makefile `bootstrap-check` and `qa-pack` no longer depend on `.omo` files; `test-ingest` no longer fabricates a JUnit report.
- `compose.yaml` Phoenix template references the committed root Dockerfile.
- `docs/production-operations.md` resolves the six runtime decisions for Railway (private networking, backups, memory, healthchecks, pre-deploy, rollback) while preserving the Docker-boundary language.

### Fixed

- `RealCatalogSourceManifestTest` made environment-robust (empty snapshot dir on clean checkouts no longer fails).
- Remaining Dialyzer `pattern_match` findings in the scrape Mix tasks.
- Makefile `.PHONY` colon escaping for the `gates:measure` target.

### Security

- Patched vulnerable Elixir dependencies (Phoenix, Plug, Mint, hpax, Bandit, Postgrex, Swoosh, ymlr, Ash) via a single `mix deps.update`.
- Sobelow findings satisfied; `hex.audit` and `uv audit` gates added.
- Content-Security-Policy added; secure session cookies; RequestLogger gated off in prod.

### Removed

- Admin surface removed: admin routes, module layer, auth domain, migration, invite task, test suites, browser-QA/adversarial admin tags, and README/AGENTS references.
- Stale root `worklog.md` archived to `docs/history/worklog-2026-06.md`.
- Local `priv/repo/structure.sql` dump ignored (untracked artifact).

### Docs

- `docs/cleanup-policy.md` authorizes the four named cleanup exceptions.
- `docs/production-readiness.md` aligns the tiered gate docs and operator entrypoints table with the actual CI jobs and Mix tasks.
- `docs/production-operations.md` resolves runtime decisions for Railway.

## [0.1.0] - 2026-08-05

### Added

- Initial release of Hiraeth, a Phoenix LiveView + Ash discovery catalog for curated independent publisher books.
- Canonical work/edition catalog graph with Ash resources, actions, and policies (`lib/hiraeth/catalog`).
- Provenance-aware ingestion: provider runs, source snapshots, record candidates, diffs, quarantine, replay, and ingestion events (`lib/hiraeth/ingestion`).
- Deterministic real-catalog corpus: dataset, policy gates, validator, and importer (`lib/hiraeth/real_catalog`).
- Oban-backed autonomous ingestion phases: plan, fetch, normalize, validate, diff, cover-cache, apply, audit, quarantine, replay, and retention cleanup.
- Private-by-default Python sidecar (FastAPI + Scrapling) with strict CORS, typed errors, contract snapshots, and URL validation.
- Local-cache-only public cover display with typographic fallbacks for unsafe or missing covers.
- Public LiveView catalog surface: `/browse`, `/search`, `/publishers`, `/series`, `/contributors`, and book detail pages.
- Operator Mix tasks for ingestion, scraping, cover caching, and provenance audits.
- Production docs: contracts, cleanup policy, operations, readiness, and provenance/cover policy.
