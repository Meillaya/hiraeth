# PROJECT KNOWLEDGE BASE

**Generated:** 2026-08-05
**Commit:** b3c94b4
**Branch:** main

## OVERVIEW
Hiraeth is a Phoenix 1.8 / LiveView discovery catalog for indie publisher and bookstore data (v1.0.0, deployed to Railway). Ash resources own domain behavior; Scrapling-powered Python sidecar handles permitted external fetch/scrape work; devenv is the preferred local/dev/test environment while the Dockerfiles remain the production-boundary reference.

## STRUCTURE
```
lib/hiraeth/             # Ash domains, catalog, ingestion, provenance, covers
lib/hiraeth/catalog      # canonical work/edition graph + Ash actions/policies
lib/hiraeth/ingestion    # provider runs, sidecar client, normalizers, replay
lib/hiraeth/real_catalog # deterministic corpus: dataset, policy gates, validator, importer
lib/hiraeth_web/         # Phoenix router, LiveViews, components, public UI
lib/mix/tasks/           # operator Mix tasks: ingest, scrape, covers, audits
test/                    # ExUnit, LiveView, fixture, and contract suites
test/support             # data_case, factories, contract fixtures
sidecar/                 # private FastAPI + Scrapling sidecar service
scripts/                 # QA/dev/catalog operational scripts
scripts/qa/browser       # Playwright/Chromium browser evidence gates
scripts/qa/ingestion     # production ingestion drills + adversarial drill
scripts/qa/perf          # perf baseline measurement harness (measure_gates.sh)
scripts/ops              # DB backup + restore-drill scripts (restore into separate DB only)
priv/                    # migrations, source data, snapshots, static covers
priv/repo/migrations     # Ash + custom migration history
priv/catalog_sources     # approved provider manifests, source registry
priv/catalog_sources/provider_manifests  # per-provider source allowlists
priv/resource_snapshots  # governed snapshot/replay evidence (incl. repo)
priv/static/covers       # hashed local cover cache (sandboxed writes only)
docs/                    # contracts, cleanup policy, production ops/readiness, provenance policy
tests/scripts            # Python pytest for scripts/catalog generators (not Elixir test/)
artifacts/qa             # QA evidence outputs (make verify, browser gates, provenance audits)
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Catalog business rules | `lib/hiraeth/catalog`, `lib/hiraeth/*.ex` | Ash domains/actions first |
| Ingestion/provenance | `lib/hiraeth/ingestion`, `lib/hiraeth/sources`, `lib/hiraeth/real_catalog` | preserve snapshots + ledgers |
| Public browser UI | `lib/hiraeth_web/live`, `lib/hiraeth_web/public_catalog.ex` | LiveView only |
| Operator Mix tasks | `lib/mix/tasks` | ingest, scrape, covers, audits |
| External fetch/scrape | `sidecar/app`, `sidecar/tests` | private sidecar, Scrapling only |
| Dev/test orchestration | `devenv.nix`, `Makefile` | devenv path is canonical |
| Browser QA | `scripts/browser_qa.sh`, `scripts/qa/browser` | Playwright/Chromium evidence gates |
| Ingestion QA drills | `scripts/qa/ingestion` | production drill + adversarial drill |
| Test support harnesses | `test/support` | data_case, factories, contract fixtures |
| Migrations | `priv/repo/migrations` | Ash + custom migration history |
| Provider manifests | `priv/catalog_sources/provider_manifests` | per-provider source allowlists |
| Source snapshots | `priv/resource_snapshots/repo` | governed snapshot/replay evidence |
| Cover cache | `priv/static/covers` | hashed local cache; sandboxed writes only |
| Governance docs | `docs/` | contracts, cleanup-policy, ops, readiness, provenance |
| DB backup/restore drills | `scripts/ops`, `Makefile` (`db-backup`, `db-restore-drill`) | restore drills target a separate DB, never live |
| Release/deployment | `Dockerfile`, `docs/production-readiness.md`, `docs/production-operations.md` | multi-stage release image; Railway |

## CODE MAP
| Symbol / file | Type | Location | Role |
|---|---|---|---|
| `Hiraeth.Application` | OTP app | `lib/hiraeth/application.ex` | starts Repo, PubSub, Oban, Endpoint |
| `HiraethWeb.Router` | router | `lib/hiraeth_web/router.ex` | public route boundary; hard CSP + `:ops` probe pipeline |
| `HiraethWeb.HealthController` | controller | `lib/hiraeth_web/controllers/health_controller.ex` | `/health` + `/ready` (DB + optional sidecar check) |
| `HiraethWeb.PublicCatalog` | query facade | `lib/hiraeth_web/public_catalog.ex` | public catalog projection/filtering |
| `Hiraeth.Catalog` | Ash domain | `lib/hiraeth/catalog.ex` | canonical work/edition graph |
| `Hiraeth.Ingestion` | Ash domain | `lib/hiraeth/ingestion.ex` | provider runs, snapshots, candidates |
| `Hiraeth.Ingestion.SidecarClient` | HTTP client | `lib/hiraeth/ingestion/sidecar_client.ex` | typed boundary to private FastAPI sidecar |
| `Hiraeth.Sources` | Ash domain | `lib/hiraeth/sources.ex` | source records, ledgers, overrides |
| `Hiraeth.RealCatalog.SourcePolicy` | policy | `lib/hiraeth/real_catalog/source_policy.ex` | source/caching allowlists |
| `Hiraeth.RealCatalog.Importer` | trusted writer | `lib/hiraeth/real_catalog/importer.ex` | idempotent corpus seed into Catalog (validator-gated) |
| `Hiraeth.RealCatalog.Validator` | policy gate | `lib/hiraeth/real_catalog/validator.ex` | pre-seed findings gate; any finding blocks import |
| `Hiraeth.ProvenanceAudit` | audit exporter | `lib/hiraeth/provenance_audit.ex` | source-ledger/takedown/cover-cache evidence exports |
| `Hiraeth.Ingestion.ManifestValidator` | manifest gate | `lib/hiraeth/ingestion/manifest_validator.ex` | validates provider manifests before ingestion accepts them |
| `Hiraeth.Covers` | domain facade | `lib/hiraeth/covers.ex` | cover cache safety + provenance |
| `Hiraeth.Oban.ProviderIngestionWorker` | Oban worker | `lib/hiraeth/oban/provider_ingestion_worker.ex` | per-provider fetch/normalize/apply pipeline |
| `Hiraeth.Oban.ProviderSchedulerWorker` | Oban worker | `lib/hiraeth/oban/provider_scheduler_worker.ex` | triggers provider runs on plan schedule |
| `Hiraeth.Oban.CoverRefreshWorker` | Oban worker | `lib/hiraeth/oban/cover_refresh_worker.ex` | weekly scheduled cover cache refresh |
| `Hiraeth.Oban.ProvenanceAuditWorker` | Oban worker | `lib/hiraeth/oban/provenance_audit_worker.ex` | weekly scheduled provenance audit export |
| `app.main` | FastAPI app | `sidecar/app/main.py` | sidecar routers + CORS/security posture |
| `scripts/browser_qa.sh` | QA entry | `scripts/browser_qa.sh` | browser evidence sweep |

## CONVENTIONS
- LiveView owns browser UI. No React, no Vite SPA, no separate frontend app in v1.
- Use `agy` for substantial page/component design exploration before implementation.
- Use TDD for domain behavior, ingestion, normalization, provenance, cover handling, and UI flows.
- Ash resources/actions/policies are the domain source of truth; do not move business rules into controllers/templates.
- Use AshPostgres for persistence and AshPhoenix for Phoenix-facing Ash integration.
- Public UI reads typed projections; never serialize raw Ash/SQL/sidecar payloads into browser paths.
- Use `Req` for Elixir HTTP. Do not add HTTPoison/Tesla/httpc.
- Tailwind v4 stays in `assets/css/app.css` with `@import "tailwindcss" source(none);` and `@source` entries; never use `@apply`.
- LiveViews start templates with `<Layouts.app flash={@flash} ...>` and pass `current_scope` where required.
- Use `<.input>`, `<.icon>`, `<.link navigate|patch>`, `to_form`, and LiveView streams for collections.
- Devenv local processes own Postgres `127.0.0.1:54320`, sidecar `127.0.0.1:8000`, Phoenix `127.0.0.1:4000`.
- Docker sidecar image (`sidecar/Dockerfile`) is the production service-network boundary; do not claim production is fully Nix/devenv-only.
- Prod runtime is hardened: force_ssl (exempts `/health`), Secure session cookie, JSON logs, `/ready` requires sidecar healthy; `DATABASE_URL` and `SCRAPLING_SIDECAR_URL` are required release env.

## ANTI-PATTERNS (THIS PROJECT)
- Broad `/api` catalog surface, public JSON API, checkout/cart/account/social/reviews features in v1.
- Custom crawlers or scraping frameworks beyond Scrapling; random/Faker catalog metadata tests.
- Removing provider manifests, real-publisher datasets, source snapshots, or source-authority records without explicit publisher-removal authorization.
- Treating publisher permission as a reason to weaken official-source/provenance rules; sourced purchase links are preserved when present in the provider manifest, but missing links remain explicit gaps and must never be fabricated.
- Hotlinking remote cover images or rendering uncached/unsafe/hidden/takedown covers publicly.
- Runtime remote fonts or third-party scripts in public UI; pages and browser captures must stay self-contained.
- Touching `priv/static/covers/cache/*` during cleanup; use the sandbox/hash guard.
- Publicly exposing the sidecar, wildcard CORS, private/loopback/link-local fetch targets, or userinfo URLs.
- `Phoenix.HTML.form_for`, `<.form let=...>`, raw inline `<script>` in HEEx, `live_redirect`, `live_patch`, `<.flash_group>` outside layouts.

## COMMANDS
```bash
nix run nixpkgs#devenv -- test
nix run nixpkgs#devenv -- up -d hiraeth-postgres
nix run nixpkgs#devenv -- shell -- mix gate
nix run nixpkgs#devenv -- shell -- mix ci
mix gate                 # Layer 0 blocking gate (compile warnings-as-errors + format check + credo --strict + test.fast)
mix test.fast
mix test.full
make verify
make test-browser
make db-backup           # scripts/ops/db_backup.sh
make db-restore-drill    # scripts/ops/db_restore_drill.sh (separate DB only)
cd sidecar && uv run --extra dev pytest -q
cd sidecar && uv run ruff check . && uv run pyright && uv audit
uv run --project . pytest tests/scripts -q   # root pyproject: catalog-generator tests
```

## NOTES
- `mix gate` checks compile with warnings-as-errors, unused deps, formatting (checks it, does not rewrite), strict Credo, and the fast test lane; sobelow/hex.audit are network-dependent and run only in `mix ci`/CI.
- `mix test.fast` excludes `slow`, `full_catalog`, `integration`, `performance`, `browser`, `public_catalog_full`.
- CI splits: `ci.yml` runs static + test-fast (postgres:16 service) on PRs and pushes to `main`; `deep.yml` runs dialyzer, the full suite as a 3-partition matrix on merge to `main` and manual dispatch, a nightly coverage job enforcing the 86.1 floor, browser QA, ingestion drills, sidecar pytest/ruff/pyright/uv-audit, scripts tests, and release image builds. The legacy Compose lane was removed; contract tests pin the lane split above.
- devenv is the local dev/test environment only; CI lanes do not invoke devenv.
- `.omx`, `.omo`, `.omc`, `_build`, `deps`, `.devenv`, `.direnv`, caches, and artifacts are workspace/tool state unless a task explicitly targets them.
- Custom Mix aliases (`gate`, `ci`, `test.fast`, `test.full`) auto-run under `MIX_ENV=test` via `preferred_envs`; `mix test` auto-creates and migrates the DB first.
- `priv/repo/structure.sql` is a gitignored, untracked local pg_dump artifact — neither governed nor referenced; do not commit it without explicit intent.
- Root `Dockerfile` builds the multi-stage release image (covers/cache symlinked to a volume mount); Docker remains the production-boundary reference while Railway runs the deployed catalog.
