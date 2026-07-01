from __future__ import annotations

from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.routers import fetch
from app.spiders.deep_vellum_stealthy import StealthyFetcher

client = TestClient(app)


def _fetch_request() -> dict[str, object]:
    return {
        "provider": "typed_error_provider",
        "config": {
            "api": {"type": "shopify", "endpoint": "https://store.example.com"},
            "source_hosts": ["store.example.com"],
        },
    }


def test_fetch_returns_rate_limited_code_when_adapter_reports_429() -> None:
    # Given: an adapter raises an upstream 429 failure.
    async def rate_limited_adapter(_config: dict[str, object]) -> list[dict[str, object]]:
        raise RuntimeError("upstream returned 429")

    with patch.dict(fetch.ADAPTERS, {"shopify": rate_limited_adapter}):
        # When: the fetch endpoint handles the adapter failure.
        response = client.post("/fetch/", json=_fetch_request())

    # Then: the response exposes a stable error code, not a stringly status.
    assert response.status_code == 429
    assert response.json()["detail"] == {
        "code": "rate_limited",
        "message": "sidecar fetch was rate limited",
    }


def test_fetch_returns_blocked_code_when_adapter_reports_forbidden() -> None:
    # Given: an adapter reports a blocked upstream response.
    async def blocked_adapter(_config: dict[str, object]) -> list[dict[str, object]]:
        raise RuntimeError("upstream returned 403")

    with patch.dict(fetch.ADAPTERS, {"shopify": blocked_adapter}):
        # When: the fetch endpoint handles the adapter failure.
        response = client.post("/fetch/", json=_fetch_request())

    # Then: blocked responses have a stable code.
    assert response.status_code == 403
    assert response.json()["detail"]["code"] == "blocked"


def test_fetch_returns_schema_changed_code_when_adapter_shape_breaks() -> None:
    # Given: an adapter hits a missing field in the upstream payload shape.
    async def schema_changed_adapter(_config: dict[str, object]) -> list[dict[str, object]]:
        raise KeyError("products")

    with patch.dict(fetch.ADAPTERS, {"shopify": schema_changed_adapter}):
        # When: the fetch endpoint handles the adapter failure.
        response = client.post("/fetch/", json=_fetch_request())

    # Then: schema failures are explicit.
    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "schema_changed"


def test_fetch_returns_network_code_when_adapter_cannot_connect() -> None:
    # Given: an adapter hits a transport-level failure.
    async def network_adapter(_config: dict[str, object]) -> list[dict[str, object]]:
        raise OSError("connection reset")

    with patch.dict(fetch.ADAPTERS, {"shopify": network_adapter}):
        # When: the fetch endpoint handles the adapter failure.
        response = client.post("/fetch/", json=_fetch_request())

    # Then: transport errors are explicit.
    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "network"


def test_fetch_returns_invalid_host_code_for_disallowed_endpoint_host() -> None:
    # Given: the endpoint host is outside the manifest allowlist.
    request = _fetch_request()
    request["config"] = {
        "api": {"type": "shopify", "endpoint": "https://evil.example.com"},
        "source_hosts": ["store.example.com"],
    }

    # When: the fetch endpoint validates the request.
    response = client.post("/fetch/", json=request)

    # Then: host validation uses the typed error contract.
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "invalid_host"


def test_scrape_returns_parse_failed_code_when_spider_fails() -> None:
    # Given: a Scrapling spider fails while parsing.
    with patch(
        "app.routers.scrape.GenericBookSpider.to_json",
        side_effect=RuntimeError("parser exploded"),
    ):
        # When: the scrape endpoint handles the spider failure.
        response = client.post(
            "/scrape/",
            json={
                "provider": "failing_publisher",
                "config": {
                    "start_urls": ["https://example.com"],
                    "source_hosts": ["example.com"],
                    "selectors": {"item": ".book", "title": "h2::text"},
                },
            },
        )

    # Then: parse failures are explicit.
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "parse_failed"


def test_detail_returns_empty_response_code_before_parsing(monkeypatch) -> None:
    # Given: the detail fetcher returns an empty body.
    async def fake_fetch_async(url: str, **_kwargs: object) -> object:
        return type("FakeResponse", (), {"url": url, "text": ""})()

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    with patch(
        "app.routers.scrape.DeepVellumStealthySpider._parse_detail",
        new_callable=Mock,
    ) as parse_detail:
        # When: detail enrichment receives the empty body.
        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "deep_vellum_official_store",
                "url": "https://store.deepvellum.org/products/rilke-shake",
            },
        )

    # Then: the endpoint fails before parsing with a stable code.
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "empty_response"
    parse_detail.assert_not_called()
