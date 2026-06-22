# Hiraeth Sidecar

FastAPI microservice that runs Scrapling spiders and fetch adapters alongside the Hiraeth Phoenix application.

## Run locally (without Docker)

Requires Python 3.11+.

```bash
cd sidecar
uv pip install -e ".[dev]"
uvicorn app.main:app --reload --port 8000
```

## Run with Docker

```bash
docker build -t hiraeth-sidecar sidecar/
docker run -p 8000:8000 hiraeth-sidecar
```

## Test

```bash
cd sidecar
pytest tests/
```

## Endpoints

- `GET /health/` — liveness probe
- `POST /fetch/` — API fetch stub (returns placeholder)
- `POST /scrape/` — Scrapling scrape stub (returns placeholder)
