import json
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient
from scrapling.spiders import Response

from app.main import app
from app.spiders.generic_book_spider import GenericBookSpider

client = TestClient(app)

FIXTURES_DIR = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


def _make_response(url: str, html: str, status: int = 200) -> Response:
    return Response(
        url, html, status, "OK" if status == 200 else "Forbidden", {}, {}, {}
    )


class TestGenericBookSpider:
    def test_extracts_correct_fields_from_mock_html(self):
        html = _load_fixture("publisher_catalog.html")
        mock_response = _make_response("https://example.com/books", html)

        spider = GenericBookSpider(
            config={
                "start_urls": ["https://example.com/books"],
                "source_hosts": ["example.com"],
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
        assert first["source_uri"] == "https://example.com/books"
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

    def test_publisher_selector_does_not_emit_unsupported_publisher_data(self):
        # Given: the fixture contains publisher text and the generic selector config names it.
        html = _load_fixture("publisher_catalog.html")
        mock_response = _make_response("https://example.com/books", html)
        spider = GenericBookSpider(
            config={
                "start_urls": ["https://example.com/books"],
                "source_hosts": ["example.com"],
                "provider": "test_publisher",
                "selectors": {
                    "item": ".book",
                    "title": "h2::text",
                    "author": ".author::text",
                    "publisher": ".publisher::text",
                    "isbn": ".isbn::text",
                },
                "download_delay": 0,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            # When: the generic spider serializes records.
            records = spider.to_json()

        # Then: current output behavior is preserved: no publisher value is emitted.
        assert len(records) == 2
        assert "Test Press" not in json.dumps(records, sort_keys=True)
        for record in records:
            assert "publisher" not in record
            assert "publisher" not in record["work"]
            assert "publisher" not in record["edition"]

    def test_rate_limiting_is_respected(self):
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
        spider = GenericBookSpider(
            config={
                "start_urls": ["http://example.com"],
                "use_stealthy_fetcher": True,
            }
        )
        assert spider.use_stealthy is True


class TestScrapeRouter:
    def test_scrape_endpoint_returns_records(self):
        html = _load_fixture("publisher_catalog.html")
        mock_response = _make_response("https://example.com/books", html)

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
                        "start_urls": ["https://example.com/books"],
                        "source_hosts": ["example.com"],
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
        mock_response = _make_response("https://example.com/empty", html)

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
                        "start_urls": ["https://example.com/empty"],
                        "source_hosts": ["example.com"],
                        "selectors": {"item": ".book", "title": "h2::text"},
                    },
                },
            )

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "success"
        assert data["records"] == []

    @pytest.mark.parametrize(
        ("config", "message_fragment"),
        [
            (
                {
                    "start_urls": ["https://127.0.0.1:8000/books"],
                    "source_hosts": ["127.0.0.1"],
                },
                "must not be private",
            ),
            (
                {
                    "start_urls": ["http://example.com/books"],
                    "source_hosts": ["example.com"],
                },
                "must be HTTPS",
            ),
            (
                {
                    "start_urls": ["https://user:pass@example.com/books"],
                    "source_hosts": ["example.com"],
                },
                "must not include userinfo",
            ),
            ({"start_urls": ["https://example.com/books"]}, "source_hosts"),
            (
                {"start_urls": ["https://example.com/books"], "source_hosts": []},
                "source_hosts",
            ),
        ],
    )
    def test_scrape_endpoint_rejects_generic_unsafe_start_urls_before_spider(
        self, config, message_fragment
    ):
        # Given: a generic scrape request has an unsafe or unallowlisted start URL.
        with patch("app.routers.scrape.GenericBookSpider") as mock_generic_spider:
            # When: the scrape endpoint validates the request.
            response = client.post(
                "/scrape/",
                json={"provider": "unknown_provider", "config": config},
            )

        # Then: validation fails before generic spider construction.
        assert response.status_code == 422
        assert response.json()["detail"]["code"] == "invalid_host"
        assert message_fragment in response.json()["detail"]["message"]
        mock_generic_spider.assert_not_called()

    @pytest.mark.parametrize(
        "alias_url",
        [
            "https://127.1/books",
            "https://0177.0.0.1/books",
            "https://2130706433/books",
            "https://0x7f000001/books",
            "https://localhost./books",
            "https://LOCALHOST./books",
        ],
    )
    def test_scrape_endpoint_rejects_generic_https_private_aliases_before_spider(
        self, alias_url
    ):
        # Given: a generic scrape URL uses HTTPS but resolves to local/private address forms.
        endpoint_host = alias_url.removeprefix("https://").split("/", 1)[0]
        with patch("app.routers.scrape.GenericBookSpider") as mock_generic_spider:
            # When: the scrape endpoint validates the request.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "unknown_provider",
                    "config": {
                        "start_urls": [alias_url],
                        "source_hosts": [endpoint_host],
                    },
                },
            )

        # Then: private-host validation, not HTTPS scheme validation, blocks execution.
        assert response.status_code == 422
        assert response.json()["detail"]["code"] == "invalid_host"
        assert "must not be private" in response.json()["detail"]["message"]
        mock_generic_spider.assert_not_called()

    def test_scrape_endpoint_returns_error_on_spider_failure(self):
        with patch(
            "app.routers.scrape.GenericBookSpider.to_json",
            side_effect=RuntimeError("spider exploded"),
        ):
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

        assert response.status_code == 422
        data = response.json()
        assert data["detail"]["code"] == "parse_failed"
        assert (
            data["detail"]["message"] == "sidecar scrape failed to parse the response"
        )
