# Hiraeth Contract Boundaries

Hiraeth v1 is a browser-first Phoenix LiveView catalog. Stable contract work means documented tiers and typed projections, not a broad public JSON API.

## Public browser contract

The public browser contract is the LiveView and HEEx experience reachable from routes such as `/`, `/browse`, `/search`, `/books/:slug`, `/publishers`, `/series`, and contributor discovery routes.

Stability promise:
- Public browser routes, query parameters, and user-visible catalog behavior should remain backward compatible within v1 whenever practical.
- Public pages may change markup, styling, and component structure without a version bump, but key route semantics and catalog filtering behavior require a migration note when changed.
- Public book metadata must come through `Hiraeth.Catalog.PublicProjection` or an explicitly reviewed successor projection. Browser code must not serialize Ash resources, SQL rows, or sidecar payloads directly.

Deprecation and version rules:
- Removing a public browser route or query parameter requires a deprecation note in release documentation before removal.
- Replacement routes should redirect or preserve user intent for at least one release cycle.
- Browser route changes are versioned by release notes, not URL `/vN` prefixes in v1.

## Stable Ash/internal contract

Ash resources and Ash actions are the stable internal domain contract for catalog, source, cover, import, search, and audit behavior. The resources own identities, relationships, validations, policies, and persistence mapping.

Stability promise:
- Internal Elixir callers should use Ash actions or typed context/projection modules, not raw table access, unless a bounded read model documents why SQL is required.
- Resource attribute and action changes require targeted tests at the resource or projection boundary.
- Public catalog reads use typed projection structs so future consumers do not couple to Ash internals.

Deprecation and version rules:
- Renaming Ash actions, attributes, identities, or relationship names requires updating call sites and tests in the same change.
- Internal breaking changes are allowed before a production release when covered by migration notes and contract tests.
- Database migrations must preserve provenance and replay needs unless a future plan explicitly retires a field.

## Local development environment contract

`devenv` is the preferred local/dev/test path for Hiraeth. It owns the pinned developer toolchain, PostgreSQL loopback service on `127.0.0.1:54320`, the Phoenix process, and the loopback Scrapling sidecar process used by local checks. Operators should run ordinary Mix work from a `devenv shell` and use the devenv process runner/readiness tasks for managed local services.

Docker remains a legacy fallback and the current production runtime boundary reference. Docker/Compose documentation should describe fallback debugging, production runtime networking, or production-boundary constraints; it must not replace devenv as the preferred local/dev/test setup, and it must not imply that production is Nix/devenv-only.

## Verification gate tiers

Verification is tiered so the fast developer loop stays under five minutes while full release assurance runs at depth:

- **Layer 0 — local blocking gate:** `mix gate` (wrapped by `make gate`/`make recheck`) is the ≤5-min blocking local preflight: compile with warnings-as-errors, unused-deps check, format check, strict Credo, and the fast ExUnit lane. It deliberately omits sobelow/hex.audit (network-dependent), dialyzer, coverage, assets, provenance, browser QA, ingestion drills, sidecar pytest, and the full devenv readiness graph.
- **Layer 1 — parallel CI:** `.github/workflows/ci.yml` runs the `static` (format/Credo/Sobelow/hex.audit) and `test-fast` jobs in parallel on every PR and push to `main`, plus a lean devenv smoke job.
- **Layer 2 — deep lane:** `.github/workflows/deep.yml` runs dialyzer, coverage, the full suite including assets, provenance audit, browser QA, ingestion drills, sidecar pytest, and the full devenv readiness graph on merge to `main`, nightly, and manual dispatch.

`mix gate` is not a substitute for the deep lane: the fast blocking gate is a local preflight, not release assurance. The deep lane must pass before any production-ready claim.

## Private sidecar contract

The Scrapling sidecar is private infrastructure for ingestion. It is not a public browser or public JSON API contract.

Stability promise:
- Sidecar request, response, and error shapes are private but reviewed because ingestion workers depend on them.
- The sidecar must stay private-by-default and reachable only by trusted runtime infrastructure.
- Local devenv uses loopback-only sidecar transport: `devenv.nix` declares a managed `scrapling-sidecar` process that binds `127.0.0.1:8000`, and direct debugging may run the same uvicorn command from a `devenv shell`. Point Phoenix/operator tasks at `SCRAPLING_SIDECAR_URL=http://127.0.0.1:8000`. This local host transport is separate from production/internal Compose networking and does not make Phoenix/sidecar production exclusive to Nix/devenv. Docker remains the production runtime and service-network reference for this boundary.
- The default Compose service must not publish a host port for the sidecar; Phoenix reaches it on the service network via `SCRAPLING_SIDECAR_URL=http://scrapling-sidecar:8000`. Any host access for local debugging must be an explicit developer override, not the committed default or production path.
- The sidecar currently exposes only internal `/health/`, `/fetch/`, `/scrape/`, and `/scrape/detail` routes. FastAPI OpenAPI, Swagger UI, OAuth redirect, and ReDoc routes are disabled by default. Browser CORS is disabled when `HIRAETH_SIDECAR_CORS_ORIGINS` is unset, configured origins must be exact HTTP(S) origins without userinfo, and wildcard origins are forbidden.
- `/fetch/` and generic `/scrape/` outbound URLs must be HTTPS, omit userinfo, resolve to public/non-local hosts, and match explicit manifest `source_hosts`; unknown-provider generic scraping is rejected without that allowlist.
- Sidecar payloads must be converted to typed Elixir ingestion data before persistence or display.
- Sidecar contract snapshots are internal review guards for ingestion workers, not public API compatibility guarantees.

Deprecation and version rules:
- Sidecar shape changes require contract tests or snapshots in the sidecar/ingestion test surface.
- Sidecar errors should use typed codes once introduced; callers must not depend on substring matching.
- Sidecar endpoint changes can be breaking only when the matching Elixir client and tests change in the same release.

## Operator task contract

Operator task contracts cover Mix tasks, health/readiness checks, and authenticated admin ingestion controls. These are operational surfaces, not public catalog APIs.

Stability promise:
- Operator commands should be scriptable, deterministic, and safe to run repeatedly where documented.
- Health and readiness endpoints may exist as narrow operations endpoints and must not expose catalog records, secrets, stack traces, or broad API discovery.
- The current narrow operations endpoints are `GET /health` and `GET /ready`; they are not mounted under `/api` and do not expose catalog data.
- Admin ingestion controls must be authenticated before mutating provider runs, quarantine decisions, replay, or scheduling.

Stable entrypoints after repository consolidation:
- Browser QA operators should use `make test-browser` or `scripts/browser_qa.sh`; direct Node diagnostics live under `scripts/qa/browser/`.
- Production ingestion drills live under `scripts/qa/ingestion/` and should be invoked by their shell scripts, not by reaching into moved test helpers.
- Catalog source maintenance scripts live under `scripts/catalog/`; they are explicit maintenance tools for checked-in source corpus refreshes, not background app runtime dependencies.
- Cleanup-policy smoke checks use `make cleanup-policy`, backed by `docs/cleanup-policy.md` and `scripts/qa/cover_cache_sandbox.sh`.
- Commands that can write cover files must preserve the root `priv/static/covers/cache/*` cache by running in the cover-cache sandbox or an equivalent temporary copy.

Deprecation and version rules:
- Operator command flags require a compatibility note before removal.
- Machine-readable operator output such as `--json` must be explicitly versioned once added.
- Narrow operations endpoints must be documented here and covered by no-scope tests if they use an `/api` prefix.

## Future JSON API rules

Hiraeth v1 does not expose a broad public JSON API. A future JSON API may be added only by a later approved plan with a named consumer, explicit route scope, versioning, authentication rules, rate-limit posture, and contract tests.

Stability promise:
- Future JSON responses must be derived from typed public projections or dedicated versioned DTOs, not raw Ash resources, SQL rows, source records, or sidecar payloads.
- No catch-all `/api`, `/api/books`, `/api/catalog`, or unversioned broad catalog route may be added in v1.
- Narrow operations endpoints are allowed only when documented as operator contracts and tested as non-catalog surfaces.

Deprecation and version rules:
- Public JSON APIs, once approved, must use an explicit version such as `/api/v1/...` or an equivalent documented media-type version.
- Public JSON fields may be added compatibly, but removals, type changes, or semantic changes require a deprecation window and contract test update.
- API error shapes must be typed and documented before external use.

## Projection governance

`Hiraeth.Catalog.PublicProjection` is the current public catalog projection seam. It defines typed structs for the work-centric book projection and nested format, contributor, cover, and source provenance values used by the public browser.

Projection rules:
- Add fields only when they are sourced, provenance-safe, and needed by a browser or approved future consumer.
- Keep raw sidecar payloads, unchecked source records, private artifact paths outside `priv/static`, and internal review state out of public projections.
- Shape tests should assert keys and types at the projection boundary instead of brittle full HTML snapshots.
