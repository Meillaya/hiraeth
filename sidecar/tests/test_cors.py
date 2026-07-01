import importlib
from types import ModuleType

import pytest
from fastapi.testclient import TestClient


def _load_main(monkeypatch: pytest.MonkeyPatch, origins: str | None) -> ModuleType:
    if origins is None:
        monkeypatch.delenv("HIRAETH_SIDECAR_CORS_ORIGINS", raising=False)
    else:
        monkeypatch.setenv("HIRAETH_SIDECAR_CORS_ORIGINS", origins)

    import app.main

    return importlib.reload(app.main)


def test_cors_denies_browser_origins_when_env_is_unset(
    monkeypatch: pytest.MonkeyPatch,
):
    # Given: the sidecar starts with no allowed browser origins configured.
    main = _load_main(monkeypatch, None)
    client = TestClient(main.app)

    # When: a browser sends an Origin header to a public endpoint.
    response = client.get("/health/", headers={"Origin": "https://hiraeth.example"})

    # Then: the response does not grant browser access.
    assert response.status_code == 200
    assert "access-control-allow-origin" not in response.headers
    assert "access-control-allow-credentials" not in response.headers


@pytest.mark.parametrize("path", ["/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"])
def test_sidecar_docs_and_schema_routes_are_not_exposed_by_default(
    monkeypatch: pytest.MonkeyPatch,
    path: str,
):
    # Given: the sidecar starts with its production-default private route surface.
    main = _load_main(monkeypatch, None)
    client = TestClient(main.app)

    # When: a client probes FastAPI's automatic documentation/schema URLs.
    response = client.get(path)

    # Then: the private sidecar exposes no automatic API discovery endpoints.
    assert response.status_code == 404


def test_cors_allows_configured_origin_when_env_is_set(
    monkeypatch: pytest.MonkeyPatch,
):
    # Given: one Phoenix origin is explicitly allowed for private deployment.
    main = _load_main(monkeypatch, "http://localhost:4000")
    client = TestClient(main.app)

    # When: that browser origin performs a CORS preflight.
    response = client.options(
        "/fetch/",
        headers={
            "Origin": "http://localhost:4000",
            "Access-Control-Request-Method": "POST",
        },
    )

    # Then: only the configured origin receives CORS access.
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://localhost:4000"
    assert response.headers["access-control-allow-credentials"] == "true"


def test_cors_denies_unconfigured_origin_when_env_is_set(
    monkeypatch: pytest.MonkeyPatch,
):
    # Given: CORS is restricted to the local Phoenix origin.
    main = _load_main(monkeypatch, "http://localhost:4000")
    client = TestClient(main.app)

    # When: an unrelated browser origin performs a CORS preflight.
    response = client.options(
        "/fetch/",
        headers={
            "Origin": "https://attacker.example",
            "Access-Control-Request-Method": "POST",
        },
    )

    # Then: the sidecar does not emit a permissive allow-origin header.
    assert response.status_code == 400
    assert "access-control-allow-origin" not in response.headers


def test_cors_rejects_wildcard_origin_configuration(
    monkeypatch: pytest.MonkeyPatch,
):
    # Given: a deployment accidentally attempts permissive wildcard CORS.
    monkeypatch.setenv("HIRAETH_SIDECAR_CORS_ORIGINS", "*")

    # When / Then: startup rejects the configuration before serving traffic.
    with pytest.raises(RuntimeError, match="Wildcard CORS origins are forbidden"):
        import app.main

        importlib.reload(app.main)


@pytest.mark.parametrize(
    "origin",
    [
        "localhost:4000",
        "http://localhost:4000/sidecar",
        "https://user:pass@trusted.example",
    ],
)
def test_cors_rejects_malformed_origin_configuration(
    monkeypatch: pytest.MonkeyPatch,
    origin: str,
):
    # Given: a deployment configures an origin that is not an exact URL origin.
    monkeypatch.setenv("HIRAETH_SIDECAR_CORS_ORIGINS", origin)

    # When / Then: startup rejects malformed browser-origin configuration.
    with pytest.raises(RuntimeError, match="CORS origin must"):
        import app.main

        importlib.reload(app.main)
