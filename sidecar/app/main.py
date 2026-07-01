import os
from typing import Final
from urllib.parse import urlparse

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routers import health, fetch, scrape

CORS_ORIGINS_ENV: Final = "HIRAETH_SIDECAR_CORS_ORIGINS"


class CorsConfigurationError(RuntimeError):
    pass


def _parse_cors_origins(raw_origins: str | None) -> list[str]:
    if raw_origins is None:
        return []

    origins = [origin.strip() for origin in raw_origins.split(",") if origin.strip()]

    for origin in origins:
        _raise_if_forbidden_origin(origin)

    return origins


def _raise_if_forbidden_origin(origin: str) -> None:
    if origin == "*" or "*" in origin:
        raise CorsConfigurationError("Wildcard CORS origins are forbidden")

    parsed = urlparse(origin)

    if parsed.scheme not in {"http", "https"} or parsed.netloc == "":
        raise CorsConfigurationError(
            f"CORS origin must include http(s) scheme and host: {origin}"
        )

    if parsed.username is not None or parsed.password is not None:
        raise CorsConfigurationError(f"CORS origin must not include userinfo: {origin}")

    if parsed.path not in {"", "/"} or parsed.params or parsed.query or parsed.fragment:
        raise CorsConfigurationError(f"CORS origin must not include a path: {origin}")


def create_app() -> FastAPI:
    sidecar_app = FastAPI(
        title="Hiraeth Sidecar",
        description="Scrapling-powered ingestion sidecar for Hiraeth catalog imports",
        version="0.1.0",
        openapi_url=None,
        docs_url=None,
        redoc_url=None,
        swagger_ui_oauth2_redirect_url=None,
    )

    allowed_origins = _parse_cors_origins(os.getenv(CORS_ORIGINS_ENV))

    if allowed_origins:
        sidecar_app.add_middleware(
            CORSMiddleware,
            allow_origins=allowed_origins,
            allow_credentials=True,
            allow_methods=["POST", "GET", "OPTIONS"],
            allow_headers=["Authorization", "Content-Type"],
        )

    sidecar_app.include_router(health.router)
    sidecar_app.include_router(fetch.router)
    sidecar_app.include_router(scrape.router)

    return sidecar_app


app = create_app()
