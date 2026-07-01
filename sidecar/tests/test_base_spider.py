"""Tests for base Scrapling spider behavior."""

from typing import Any
from unittest.mock import AsyncMock, patch

from scrapling.spiders import Response

from app.spiders.base_spider import BaseSpider


def _make_response(url: str, html: str, status: int = 200) -> Response:
    return Response(url, html, status, "OK" if status == 200 else "Forbidden", {}, {}, {})


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
