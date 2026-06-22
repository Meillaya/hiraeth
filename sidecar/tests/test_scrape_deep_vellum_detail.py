"""Deep Vellum detail scrape router tests."""

from pathlib import Path
from typing import Final
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.spiders.deep_vellum_stealthy import DeepVellumStealthySpider, StealthyFetcher

client = TestClient(app)
FIXTURES_DIR: Final = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


class TestDeepVellumDetailScrapeRouter:
    def test_scrape_detail_endpoint_returns_deep_vellum_enrichment(self, monkeypatch):
        async def fake_fetch_async(url: str, **_kwargs):
            return type(
                "FakeResponse",
                (),
                {"url": url, "text": _load_fixture("deep_vellum_stealthy_detail_rilke.html")},
            )()

        monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "deep_vellum_official_store",
                "url": "https://store.deepvellum.org/products/rilke-shake",
            },
        )

        assert response.status_code == 200
        data = response.json()
        assert data["vendor"] == "deep_vellum_official_store"
        assert data["source_uri"] == "https://store.deepvellum.org/products/rilke-shake"
        assert data["contributors"] == [
            {"name": "Angélica Freitas", "role": "author"},
            {"name": "Hilary Kaplan", "role": "translator"},
        ]
        assert data["isbn_13"] == "9781939419545"
        assert data["published_on"] == "2015-03-24"
        assert data["cover"]["source_url"] == "https://cdn.shopify.com/deep-vellum/rilke-detail.jpg"
        assert "script-like text treated as inert copy" in data["description"]

    def test_scrape_detail_endpoint_rejects_over_max_bytes_before_parsing(self, monkeypatch):
        fixture = _load_fixture("deep_vellum_stealthy_detail_rilke.html")
        parsed = False

        async def fake_fetch_async(url: str, **_kwargs):
            return type("FakeResponse", (), {"url": url, "text": fixture})()

        def forbidden_parse_detail(cls, html: str):
            nonlocal parsed
            parsed = True
            raise AssertionError("detail fixture must be byte-checked before parsing")

        monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)
        monkeypatch.setattr(
            DeepVellumStealthySpider,
            "_parse_detail",
            classmethod(forbidden_parse_detail),
        )

        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "deep_vellum_official_store",
                "url": "https://store.deepvellum.org/products/rilke-shake",
                "max_bytes": len(fixture.encode("utf-8")) - 1,
            },
        )

        assert response.status_code == 422
        assert response.json()["detail"] == (
            f"fetched response exceeded max_bytes={len(fixture.encode('utf-8')) - 1}"
        )
        assert parsed is False

    def test_scrape_detail_endpoint_rejects_non_allowlisted_host(self):
        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "deep_vellum_official_store",
                "url": "https://evil.com/products/rilke-shake",
            },
        )

        assert response.status_code == 422
        assert response.json()["detail"]

    def test_scrape_detail_endpoint_rejects_query_urls(self):
        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "deep_vellum_official_store",
                "url": "https://store.deepvellum.org/products/rilke-shake?variant=1",
            },
        )

        assert response.status_code == 422
        assert response.json()["detail"]

    def test_scrape_detail_endpoint_rejects_nested_product_paths(self):
        # Given: a Deep Vellum detail URL with a valid-looking handle plus an extra path segment.
        with patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async:
            # When: the detail endpoint receives the nested product URL.
            response = client.post(
                "/scrape/detail",
                json={
                    "vendor": "deep_vellum_official_store",
                    "url": "https://store.deepvellum.org/products/rilke-shake/extra",
                },
            )

        # Then: the endpoint rejects it before fetching remote content.
        assert response.status_code == 422
        assert response.json()["detail"] == "Detail URL must target a Deep Vellum product"
        fetch_async.assert_not_awaited()
