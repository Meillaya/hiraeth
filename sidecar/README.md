# Hiraeth Sidecar

FastAPI microservice that runs Scrapling spiders and fetch adapters alongside the Hiraeth Phoenix application.

## Run locally (without Docker)

Requires Python 3.11+.

```bash
cd sidecar
uv pip install -e ".[dev]"
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

## Run with Docker

```bash
docker build -t hiraeth-sidecar sidecar/
docker run -p 127.0.0.1:8000:8000 hiraeth-sidecar
```

The direct `docker run` command is for local debugging and binds only to
loopback. In the committed Compose path, the sidecar is private-by-default:
`compose.yaml` uses `expose: ["8000"]` and does not publish a host `ports`
entry for `scrapling-sidecar`, so Phoenix reaches it over the service network
with `SCRAPLING_SIDECAR_URL=http://scrapling-sidecar:8000`.

If a developer needs host access while using Compose, create an uncommitted local override instead of changing the default file:

```yaml
# compose.sidecar-local-ports.override.yaml (local debugging only)
services:
  scrapling-sidecar:
    ports:
      - "127.0.0.1:8000:8000"
```

Do not expose the sidecar directly to the public internet.

## CORS

Browser CORS is disabled unless explicit origins are configured. Set
`HIRAETH_SIDECAR_CORS_ORIGINS` to a comma-separated list of exact Phoenix
origins that may call the sidecar from a browser:

```bash
HIRAETH_SIDECAR_CORS_ORIGINS=http://localhost:4000 uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Origins must include an `http` or `https` scheme and host, for example
`http://localhost:4000` or `https://catalog.example.com`. Wildcards such as
`*` are rejected at startup. Server-to-server calls from Phoenix do not need
CORS; prefer keeping the sidecar private and unset this variable in production
unless browser access is explicitly required.

## Test

```bash
cd sidecar
pytest tests/
```

## Endpoints

- `GET /health/` — liveness probe
- `POST /fetch/` — allowlisted provider API fetch. API endpoints must be HTTPS, must not include userinfo, must have a public host, and must match `config.source_hosts`.
- `POST /scrape/` — Scrapling catalog scrape. Provider-specific spiders retain their own allowlists; generic/unknown-provider scraping requires non-empty `config.start_urls` whose HTTPS public hosts exactly match explicit `config.source_hosts`.
- `POST /scrape/detail` — allowlisted publisher detail enrichment.
