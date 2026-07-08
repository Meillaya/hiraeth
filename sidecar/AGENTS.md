# SIDECAR KNOWLEDGE BASE

## OVERVIEW
Private FastAPI + Pydantic + Scrapling service for approved provider fetch/scrape paths. It is an internal ingestion helper, not a public API.

## STRUCTURE
| Area | Owns |
|---|---|
| `app/main.py` | FastAPI app, router registration, CORS/security posture |
| `app/models.py` | request/response models, typed error contract |
| `app/url_validation.py` | HTTPS, host allowlist, private-network rejection |
| `app/routers/fetch.py` | adapter-backed `/fetch/` endpoint |
| `app/routers/scrape.py` | spider-backed `/scrape/` and `/scrape/detail/` endpoints |
| `app/adapters/` | Shopify/Woo/Squarespace/WordPress fetch adapters |
| `app/spiders/` | provider-specific Scrapling spiders/parsers |
| `tests/` | pytest contract, URL safety, CORS, provider behavior |

## COMMANDS
```bash
uv run --extra dev uvicorn app.main:app --host 127.0.0.1 --port 8000
uv run --extra dev pytest -q
pytest tests/
```

## CONVENTIONS
- Use Scrapling only for scraping. Do not add another crawler/scraping framework.
- Keep docs/openapi/redoc UI disabled unless a task explicitly changes the private contract.
- CORS is env-driven by `HIRAETH_SIDECAR_CORS_ORIGINS`, exact-origin only, never wildcard.
- URL validation rejects private, loopback, link-local, localhost/internal, userinfo, and non-HTTPS fetch URLs unless a test fixture explicitly covers rejection.
- Routers map failures through typed errors from `models.py`; preserve error codes and snapshot contracts.
- Tests patch network calls with fixtures/mocks; do not require live external network for pytest.
- Async tests use existing anyio/pytest patterns; keep fixture HTML deterministic.
- Devenv loopback is preferred locally; Dockerfile/Compose remain fallback and production-boundary reference.

## ANTI-PATTERNS
- Binding the sidecar publicly in local guidance or default Compose.
- Adding discovery endpoints, broad provider enumeration, wildcard CORS, or public OpenAPI docs.
- Letting provider-specific URL checks drift into ad hoc string matching in routers.
- Returning untyped raw exceptions or changing snapshot output without updating contract tests.
- Downloading browsers at runtime when Nix/devenv supplies the browser executable.
