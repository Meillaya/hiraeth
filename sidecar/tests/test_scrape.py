"""Tests for the Scrapling scrape router and spiders."""

from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
from scrapling.spiders import Response

from app.main import app
from app.spiders.base_spider import BaseSpider
from app.spiders.generic_book_spider import GenericBookSpider
from app.spiders.deep_vellum_stealthy import StealthyFetcher

client = TestClient(app)

FIXTURES_DIR = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


def _make_response(url: str, html: str, status: int = 200) -> Response:
    return Response(url, html, status, "OK" if status == 200 else "Forbidden", {}, {}, {})


class TestGenericBookSpider:
    """Unit tests for GenericBookSpider with mock HTML fixtures."""

    def test_extracts_correct_fields_from_mock_html(self):
        html = _load_fixture("publisher_catalog.html")
        mock_response = _make_response("http://example.com/books", html)

        spider = GenericBookSpider(
            config={
                "start_urls": ["http://example.com/books"],
                "provider": "test_publisher",
                "selectors": {
                    "item": ".book",
                    "title": "h2::text",
                    "author": ".author::text",
                    "publisher": ".publisher::text",
                    "isbn": ".isbn::text",
                    "cover": ".cover::attr(src)",
                    "description": ".description::text",
                    "publication_date": ".date::text",
                },
                "download_delay": 0,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            records = spider.to_json()

        assert len(records) == 2

        first = records[0]
        assert first["provider"] == "test_publisher"
        assert first["source_uri"] == "http://example.com/books"
        assert first["work"]["title"] == "The Book of Tests"
        assert first["edition"]["isbn_13"] == "9781234567890"
        assert first["edition"]["published_on"] == "2024-01-15"
        assert first["cover"]["source_url"] == "https://example.com/cover1.jpg"
        assert first["description"] == "A fascinating book about testing."
        assert first["contributors"] == [{"name": "Alice Writer", "role": "author"}]

        second = records[1]
        assert second["work"]["title"] == "Another Test Book"
        assert second["edition"]["isbn_13"] == "9780987654321"
        assert second["contributors"] == [{"name": "Bob Author", "role": "author"}]

    def test_rate_limiting_is_respected(self):
        """Verify that download_delay and concurrent_requests are applied."""
        spider = GenericBookSpider(
            config={
                "start_urls": ["http://example.com"],
                "download_delay": 2.5,
                "concurrent_requests": 1,
                "max_blocked_retries": 5,
            }
        )

        assert spider.download_delay == 2.5
        assert spider.concurrent_requests == 1
        assert spider.max_blocked_retries == 5

    def test_blocked_retry_eventually_succeeds(self):
        """Simulate a blocked response followed by a successful one."""
        html = _load_fixture("publisher_catalog.html")
        success_response = _make_response("http://example.com/books", html, 200)
        blocked_response = _make_response("http://example.com/books", "Blocked", 403)

        spider = GenericBookSpider(
            config={
                "start_urls": ["http://example.com/books"],
                "provider": "test_publisher",
                "selectors": {"item": ".book", "title": "h2::text"},
                "download_delay": 0,
                "max_blocked_retries": 2,
            }
        )

        call_count = 0

        async def _mock_fetch(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return blocked_response
            return success_response

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new=_mock_fetch,
        ):
            records = spider.to_json()

        assert call_count == 2
        assert len(records) == 2
        assert records[0]["work"]["title"] == "The Book of Tests"

    def test_xpath_selectors(self):
        """Verify that XPath selectors work alongside CSS selectors."""
        html = """<html><body>
            <div class="book"><h2>XPath Book</h2><span class="author">XPath Author</span></div>
        </body></html>"""
        mock_response = _make_response("http://example.com/xpath", html)

        spider = GenericBookSpider(
            config={
                "start_urls": ["http://example.com/xpath"],
                "provider": "xpath_test",
                "selectors": {
                    "item": "//div[@class='book']",
                    "title": "h2::text",
                    "author": ".author::text",
                },
                "download_delay": 0,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            records = spider.to_json()

        assert len(records) == 1
        assert records[0]["work"]["title"] == "XPath Book"
        assert records[0]["contributors"][0]["name"] == "XPath Author"

    def test_stealthy_fetcher_config(self):
        """Verify that use_stealthy_fetcher is stored in config."""
        spider = GenericBookSpider(
            config={
                "start_urls": ["http://example.com"],
                "use_stealthy_fetcher": True,
            }
        )
        assert spider.use_stealthy is True


class TestScrapeRouter:
    """Integration tests for the POST /scrape endpoint."""

    def test_scrape_endpoint_returns_records(self):
        html = _load_fixture("publisher_catalog.html")
        mock_response = _make_response("http://example.com/books", html)

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            response = client.post(
                "/scrape/",
                json={
                    "provider": "test_publisher",
                    "config": {
                        "start_urls": ["http://example.com/books"],
                        "selectors": {
                            "item": ".book",
                            "title": "h2::text",
                            "author": ".author::text",
                            "publisher": ".publisher::text",
                            "isbn": ".isbn::text",
                            "cover": ".cover::attr(src)",
                            "description": ".description::text",
                            "publication_date": ".date::text",
                        },
                    },
                },
            )

        assert response.status_code == 200
        data = response.json()
        assert data["provider"] == "test_publisher"
        assert data["status"] == "success"
        assert len(data["records"]) == 2
        assert data["records"][0]["work"]["title"] == "The Book of Tests"

    def test_scrape_endpoint_empty_catalog(self):
        html = "<html><body></body></html>"
        mock_response = _make_response("http://example.com/empty", html)

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            response = client.post(
                "/scrape/",
                json={
                    "provider": "empty_publisher",
                    "config": {
                        "start_urls": ["http://example.com/empty"],
                        "selectors": {"item": ".book", "title": "h2::text"},
                    },
                },
            )

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "success"
        assert data["records"] == []

    def test_scrape_endpoint_returns_error_on_spider_failure(self):
        with patch(
            "app.routers.scrape.GenericBookSpider.to_json",
            side_effect=Exception("spider exploded"),
        ):
            response = client.post(
                "/scrape/",
                json={
                    "provider": "failing_publisher",
                    "config": {
                        "start_urls": ["http://example.com"],
                        "selectors": {"item": ".book", "title": "h2::text"},
                    },
                },
            )

        assert response.status_code == 200
        data = response.json()
        assert data["provider"] == "failing_publisher"
        assert data["status"].startswith("error:")
        assert "spider exploded" in data["status"]
        assert data["records"] == []

    def test_scrape_endpoint_dispatches_deep_vellum_default_to_stealthy(self):
        with patch("app.routers.scrape.DeepVellumStealthySpider") as mock_stealthy_spider:
            mock_instance = mock_stealthy_spider.return_value
            mock_instance.scrape_catalog = AsyncMock(return_value=[{"title": "Stealthy Book"}])

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {
                        "start_urls": ["https://store.deepvellum.org/collections/all"],
                    },
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum_official_store"
            assert data["status"] == "success"
            assert data["records"] == [{"title": "Stealthy Book"}]
            mock_instance.scrape_catalog.assert_awaited_once_with(
                {
                    "start_urls": ["https://store.deepvellum.org/collections/all"],
                    "provider": "deep_vellum_official_store",
                }
            )

    def test_scrape_endpoint_dispatches_deep_vellum_stealthy_by_scraper_config(self):
        with patch("app.routers.scrape.DeepVellumStealthySpider") as mock_stealthy_spider:
            mock_instance = mock_stealthy_spider.return_value
            mock_instance.scrape_catalog = AsyncMock(return_value=[{"title": "Stealthy Book"}])

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum",
                    "config": {"scraper": "stealthy"},
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum"
            assert data["records"] == [{"title": "Stealthy Book"}]
            mock_instance.scrape_catalog.assert_awaited_once_with(
                {"scraper": "stealthy", "provider": "deep_vellum"}
            )

    def test_scrape_endpoint_dispatches_deep_vellum_legacy_spider_by_scraper_config(self):
        with patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider:
            mock_instance = mock_dv_spider.return_value
            mock_instance.to_json.return_value = [{"title": "Legacy Deep Vellum Book"}]

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum",
                    "config": {
                        "start_urls": ["http://example.com"],
                        "scraper": "spider",
                    },
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum"
            assert data["status"] == "success"
            assert data["records"] == [{"title": "Legacy Deep Vellum Book"}]
            mock_dv_spider.assert_called_once_with(
                config={
                    "start_urls": ["http://example.com"],
                    "scraper": "spider",
                    "provider": "deep_vellum",
                }
            )

    def test_scrape_endpoint_dispatches_deep_vellum_legacy_spider_by_flag(self):
        with patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider:
            mock_instance = mock_dv_spider.return_value
            mock_instance.to_json.return_value = [{"title": "Legacy Deep Vellum Book"}]

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {"use_stealthy_scraper": False},
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum_official_store"
            assert data["records"] == [{"title": "Legacy Deep Vellum Book"}]
            mock_dv_spider.assert_called_once_with(
                config={"use_stealthy_scraper": False, "provider": "deep_vellum_official_store"}
            )

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
        assert data["published_on"] == "March 24, 2015"
        assert data["cover"]["source_url"] == "https://cdn.shopify.com/deep-vellum/rilke-detail.jpg"
        assert "script-like text treated as inert copy" in data["description"]

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

    def test_scrape_endpoint_dispatches_generic_book_spider_for_unknown_provider(self):
        with patch("app.routers.scrape.GenericBookSpider") as mock_generic_spider:
            mock_instance = mock_generic_spider.return_value
            mock_instance.to_json.return_value = [{"title": "Generic Book"}]

            response = client.post(
                "/scrape/",
                json={
                    "provider": "unknown_provider",
                    "config": {
                        "start_urls": ["http://example.com"],
                    },
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "unknown_provider"
            assert data["status"] == "success"
            assert data["records"] == [{"title": "Generic Book"}]
            mock_generic_spider.assert_called_once_with(config={"start_urls": ["http://example.com"], "provider": "unknown_provider"})


class TestBaseSpider:
    """Tests for BaseSpider behaviour."""

    def test_to_json_runs_spider_and_returns_items(self):
        html = "<html><body><div class='item'>Hello</div></body></html>"
        mock_response = _make_response("http://example.com", html)

        class DummySpider(BaseSpider):
            name = "dummy"

            async def parse(self, response: Response) -> Any:
                for item in response.css(".item"):
                    yield {"text": item.css("::text").get()}

        spider = DummySpider(
            config={"start_urls": ["http://example.com"], "download_delay": 0}
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            items = spider.to_json()

        assert items == [{"text": "Hello"}]

    def test_default_config_values(self):
        spider = BaseSpider(config={"start_urls": ["http://example.com"]})
        assert spider.download_delay == 0
        assert spider.concurrent_requests == 4
        assert spider.max_blocked_retries == 3
        assert spider.use_stealthy is False
