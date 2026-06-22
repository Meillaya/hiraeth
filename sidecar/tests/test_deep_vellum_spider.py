"""Tests for the Deep Vellum Scrapling spider."""

from pathlib import Path
from unittest.mock import AsyncMock, patch

from scrapling.spiders import Request, Response

from app.models import BookRecord
from app.spiders.deep_vellum_spider import DeepVellumSpider

FIXTURES_DIR = Path(__file__).parent / "fixtures"


CATALOG_URL = "https://store.deepvellum.org/collections/all"
DETAIL_RILKE_URL = "https://store.deepvellum.org/products/rilke-shake"
DETAIL_BRAZILLIONAIRES_URL = "https://store.deepvellum.org/products/brazillionaires"
LOAD_MORE_URL = "https://store.deepvellum.org/collections/all?view=sparq-load-more&page=2"


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


def _make_response(url: str, html: str, status: int = 200) -> Response:
    response = Response(
        url,
        html,
        status,
        "OK" if status == 200 else "Forbidden",
        {},
        {},
        {},
    )
    response.request = Request(url)
    return response


def _fixture_response_for_request(request: Request) -> Response:
    url = request.url
    if url == CATALOG_URL or url == LOAD_MORE_URL:
        response = _make_response(url, _load_fixture("deep_vellum_catalog.html"))
    elif url == DETAIL_RILKE_URL:
        response = _make_response(url, _load_fixture("deep_vellum_detail_rilke.html"))
    elif url == DETAIL_BRAZILLIONAIRES_URL:
        response = _make_response(url, _load_fixture("deep_vellum_detail_brazillionaires.html"))
    else:
        raise ValueError(f"Unexpected URL in test fixture router: {url}")
    response.request = request
    response.meta = {**request.meta, **response.meta}
    return response


class TestDeepVellumSpider:
    """Unit tests for DeepVellumSpider using deterministic HTML fixtures."""

    def test_filters_non_deep_vellum_vendors(self):
        """Only Deep Vellum / Deep Vellum Publishing products become records."""
        spider = DeepVellumSpider(
            config={
                "start_urls": [CATALOG_URL],
                "provider": "deep_vellum_official_store",
                "download_delay": 0,
                "max_pages": 1,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            side_effect=lambda request: _fixture_response_for_request(request),
        ):
            records = spider.to_json()

        assert len(records) == 2
        titles = {r["work"]["title"] for r in records}
        assert "Rilke Shake" in titles
        assert "Brazillionaires" in titles
        assert "Some Other Book" not in titles

    def test_records_have_required_fields(self):
        """Emitted records match the BookRecord schema and carry provenance."""
        spider = DeepVellumSpider(
            config={
                "start_urls": [CATALOG_URL],
                "provider": "deep_vellum_official_store",
                "download_delay": 0,
                "max_pages": 1,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            side_effect=lambda request: _fixture_response_for_request(request),
        ):
            records = spider.to_json()

        assert len(records) == 2
        for record in records:
            _ = BookRecord(**record)
            assert record["provider"] == "deep_vellum_official_store"
            assert record["source_product_id"]
            assert record["publisher"] in {"Deep Vellum", "Deep Vellum Publishing"}
            assert record["work"]["title"]
            assert record["edition"]["isbn_13"]
            assert record["field_sources"]
            assert record["field_sources"]["isbn_13"]["source_uri"].startswith(
                "https://store.deepvellum.org/products/"
            )

    def test_isbn_and_contributors_extraction(self):
        """Detail-page ISBN and contributor roles are parsed correctly."""
        spider = DeepVellumSpider(
            config={
                "start_urls": [CATALOG_URL],
                "provider": "deep_vellum_official_store",
                "download_delay": 0,
                "max_pages": 1,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            side_effect=lambda request: _fixture_response_for_request(request),
        ):
            records = spider.to_json()

        by_title = {r["work"]["title"]: r for r in records}

        rilke = by_title["Rilke Shake"]
        assert rilke["edition"]["isbn_13"] == "9781939419545"
        assert rilke["edition"]["published_on"] == "March 24, 2015"
        assert rilke["description"]
        assert {"name": "Angélica Freitas", "role": "author"} in rilke["contributors"]
        assert {"name": "Hilary Kaplan", "role": "translator"} in rilke["contributors"]

        braz = by_title["Brazillionaires"]
        assert braz["edition"]["isbn_13"] == "9781939419552"
        assert braz["edition"]["published_on"] == "July 12, 2016"
        assert {"name": "Alex Cuadros", "role": "author"} in braz["contributors"]

    def test_cover_prefers_data_src_when_src_is_loader(self):
        """The lazy-loader cover image is resolved via data-src."""
        html = _load_fixture("deep_vellum_catalog.html")
        response = _make_response(CATALOG_URL, html)
        spider = DeepVellumSpider()

        cards = response.css(".sparq-result-inner")
        assert len(cards) == 3
        assert spider.cover_url(cards[0]) == (
            "https://cdn.shopify.com/s/files/1/0000/0001/0001/rilke-shake-cover.jpg"
        )
        assert spider.cover_url(cards[1]) == (
            "https://cdn.shopify.com/s/files/1/0000/0001/0001/brazillionaires-cover.jpg"
        )

    def test_load_more_button_is_followed(self):
        """The Sparq load-more button is detected and followed for pagination."""
        fetched_urls: list[str] = []

        async def _mock_fetch(request):
            fetched_urls.append(request.url)
            return _fixture_response_for_request(request)

        spider = DeepVellumSpider(
            config={
                "start_urls": [CATALOG_URL],
                "provider": "deep_vellum_official_store",
                "download_delay": 0,
                "max_pages": 2,
            }
        )

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            side_effect=_mock_fetch,
        ):
            records = spider.to_json()

        assert LOAD_MORE_URL in fetched_urls
        assert len(records) == 2

    def test_empty_catalog_yields_no_records(self):
        """A page with no product grid produces no records."""
        spider = DeepVellumSpider(
            config={
                "start_urls": [CATALOG_URL],
                "provider": "deep_vellum_official_store",
                "download_delay": 0,
                "max_pages": 1,
            }
        )
        empty_response = _make_response(CATALOG_URL, "<html><body></body></html>")

        with patch(
            "scrapling.spiders.session.SessionManager.fetch",
            new_callable=AsyncMock,
            return_value=empty_response,
        ):
            records = spider.to_json()

        assert records == []

    def test_vendor_normalization(self):
        """Uppercase vendor text is normalized for filtering and output."""
        spider = DeepVellumSpider()
        assert spider.is_allowed_vendor("DEEP VELLUM")
        assert spider.is_allowed_vendor("deep vellum publishing")
        assert not spider.is_allowed_vendor("A STRANGE OBJECT")
        assert spider.normalize_vendor("DEEP VELLUM") == "Deep Vellum"
