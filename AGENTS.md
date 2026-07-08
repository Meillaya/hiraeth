# PROJECT KNOWLEDGE BASE

**Generated:** 2026-07-08
**Commit:** 327fed2
**Branch:** main

## OVERVIEW
Hiraeth is a Phoenix 1.8 / LiveView discovery catalog for indie publisher and bookstore data. Ash resources own domain behavior; Scrapling-powered Python sidecar handles permitted external fetch/scrape work; devenv is the preferred local/dev/test environment while Docker/Compose remains fallback and production-boundary reference.

## STRUCTURE
```
lib/hiraeth/          # Ash domains, catalog, ingestion, provenance, covers
lib/hiraeth_web/      # Phoenix router, LiveViews, components, public/admin UI
lib/mix/tasks/        # operator Mix tasks: ingest, scrape, covers, audits
sidecar/              # private FastAPI + Scrapling sidecar service
scripts/              # QA/dev/catalog operational scripts
test/                 # ExUnit, LiveView, fixture, and contract suites
priv/                 # migrations, source data, snapshots, static covers
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Catalog business rules | `lib/hiraeth/catalog`, `lib/hiraeth/*.ex` | Ash domains/actions first |
| Ingestion/provenance | `lib/hiraeth/ingestion`, `lib/hiraeth/sources`, `lib/hiraeth/real_catalog` | preserve snapshots + ledgers |
| Public browser UI | `lib/hiraeth_web/live`, `lib/hiraeth_web/public_catalog.ex` | LiveView only |
| Admin UI/auth | `lib/hiraeth_web/live/admin`, `router.ex`, `controllers/admin_auth.ex` | `live_session :admin` boundary |
| External fetch/scrape | `sidecar/app`, `sidecar/tests` | private sidecar, Scrapling only |
| Dev/test orchestration | `devenv.nix`, `Makefile`, `.github/workflows/ci.yml` | devenv path is canonical |
| Browser/ingestion QA | `scripts/browser_qa.sh`, `scripts/qa` | artifact-producing gates |
| Source corpus/cache | `priv/catalog_sources`, `priv/source_snapshots`, `priv/static/covers/cache` | governed evidence, not scratch |

## CODE MAP
| Symbol / file | Type | Location | Role |
|---|---|---|---|
| `Hiraeth.Application` | OTP app | `lib/hiraeth/application.ex` | starts Repo, PubSub, Oban, Endpoint |
| `HiraethWeb.Router` | router | `lib/hiraeth_web/router.ex` | public/admin route boundary |
| `HiraethWeb.PublicCatalog` | query facade | `lib/hiraeth_web/public_catalog.ex` | public catalog projection/filtering |
| `Hiraeth.Catalog` | Ash domain | `lib/hiraeth/catalog.ex` | canonical work/edition graph |
| `Hiraeth.Ingestion` | Ash domain | `lib/hiraeth/ingestion.ex` | provider runs, snapshots, candidates |
| `Hiraeth.Sources` | Ash domain | `lib/hiraeth/sources.ex` | source records, ledgers, overrides |
| `Hiraeth.RealCatalog.SourcePolicy` | policy | `lib/hiraeth/real_catalog/source_policy.ex` | source/caching allowlists |
| `Hiraeth.Covers` | domain facade | `lib/hiraeth/covers.ex` | cover cache safety + provenance |
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
- Docker/Compose sidecar remains private service-network fallback; do not claim production is fully Nix/devenv-only.

## ANTI-PATTERNS (THIS PROJECT)
- Broad `/api` catalog surface, public JSON API, checkout/cart/account/social/reviews features in v1.
- Custom crawlers or scraping frameworks beyond Scrapling; random/Faker catalog metadata tests.
- Removing provider manifests, real-publisher datasets, source snapshots, or source-authority records without explicit publisher-removal authorization.
- Treating publisher permission as a reason to weaken official-source/provenance rules; sourced non-commerce metadata is allowed only with publisher purchase links and traceable provenance.
- Hotlinking remote cover images or rendering uncached/unsafe/hidden/takedown covers publicly.
- Touching `priv/static/covers/cache/*` during cleanup; use the sandbox/hash guard.
- Publicly exposing the sidecar, wildcard CORS, private/loopback/link-local fetch targets, or userinfo URLs.
- `Phoenix.HTML.form_for`, `<.form let=...>`, raw inline `<script>` in HEEx, `live_redirect`, `live_patch`, `<.flash_group>` outside layouts.

## COMMANDS
```bash
nix run nixpkgs#devenv -- test
nix run nixpkgs#devenv -- up -d hiraeth-postgres
nix run nixpkgs#devenv -- shell -- mix precommit
nix run nixpkgs#devenv -- shell -- mix ci
mix test.fast
mix test.full
make verify
make test-browser
cd sidecar && uv run --extra dev pytest -q
```

## NOTES
- `mix precommit` delegates to `mix precommit.fast`; it checks formatting, it does not rewrite it.
- `mix test.fast` excludes `slow`, `full_catalog`, `integration`, `performance`, `browser`, `public_catalog_full`.
- CI has a devenv lane plus legacy Compose/Postgres comparison lane; keep both contract tests truthful.
- `.omx`, `.omo`, `.omc`, `_build`, `deps`, `.devenv`, `.direnv`, caches, and artifacts are workspace/tool state unless a task explicitly targets them.
