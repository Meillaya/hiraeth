import json
from collections.abc import Sequence
from typing import Any
from unittest.mock import patch

import anyio

from app.adapters.woocommerce import fetch


class MockResponse:
    def __init__(self, body: list[dict[str, Any]]) -> None:
        self.content = json.dumps(body).encode("utf-8")
        self._body = body

    def raise_for_status(self) -> None:
        return None

    def json(self) -> list[dict[str, Any]]:
        return self._body


class MockAsyncClient:
    def __init__(self, pages: Sequence[list[dict[str, Any]]]) -> None:
        self._pages = list(pages)
        self.urls: list[str] = []

    async def __aenter__(self) -> "MockAsyncClient":
        return self

    async def __aexit__(self, *args: object) -> None:
        return None

    async def get(self, url: str) -> MockResponse:
        self.urls.append(url)
        if not self._pages:
            msg = "No more mock WooCommerce responses"
            raise AssertionError(msg)
        return MockResponse(self._pages.pop(0))


def _run_woocommerce_fetch(products: list[dict[str, Any]], *, publisher_name: str | None = None) -> list[dict[str, Any]]:
    client = MockAsyncClient([products])
    config: dict[str, Any] = {
        "provider": "sandorf_passage_official_store",
        "api": {"type": "woocommerce", "endpoint": "https://sandorfpassage.org"},
        "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
    }
    if publisher_name is not None:
        config["publisher_name"] = publisher_name

    with patch("app.adapters.woocommerce.httpx.AsyncClient", return_value=client):
        return anyio.run(fetch, config)


def test_fetch_woocommerce_extracts_isbn13_from_sandorf_numeric_tag_when_sku_missing() -> None:
    # Given: Sandorf-style WooCommerce data where ISBN/contributors live in tags.
    products = [
        {
            "id": 33,
            "name": "Sample Sandorf Book",
            "permalink": "https://sandorfpassage.org/product/sample-sandorf-book/",
            "sku": "",
            "date_created": "2025-01-01T00:00:00",
            "short_description": "<p>Translated by Jane Translator.</p>",
            "images": [{"src": "https://sandorfpassage.org/wp-content/uploads/sample.jpg"}],
            "categories": [{"name": "Books"}],
            "tags": [
                {"name": "9789533516004"},
                {"name": "Croatia"},
                {"name": "Sample Author"},
                {"name": "Jane Translator"},
            ],
            "meta_data": [],
        }
    ]

    # When: the WooCommerce adapter normalizes the product.
    records = _run_woocommerce_fetch(products, publisher_name="Sandorf Passage")

    # Then: the ISBN is populated from the valid tag and no ISBN missing field remains.
    record = records[0]
    assert record["edition"]["isbn_13"] == "9789533516004"
    assert record["source_sku"] == "9789533516004"
    assert record["source_product_id"] == "33-9789533516004"
    assert "isbn_13" in record["displayed_fields"]
    assert "missing_fields" not in record
    assert record["publisher"] == "Sandorf Passage"
    assert record["description"] == "Translated by Jane Translator."
    assert record["contributors"] == [
        {"name": "Sample Author", "role": "author"},
        {"name": "Jane Translator", "role": "translator"},
    ]


def test_fetch_woocommerce_preserves_two_lines_source_uri_for_detail_enrichment_when_sku_missing() -> None:
    # Given: Two Lines-style WooCommerce data with no SKU and no ISBN in product tags.
    products = [
        {
            "id": 87,
            "name": "Lion Cross Point",
            "permalink": "https://www.twolinespress.com/shop/books/lion-cross-point/",
            "sku": "",
            "date_created": "2018-03-13T00:00:00",
            "short_description": "A haunting coming-of-age novel.",
            "images": [{"src": "https://www.twolinespress.com/wp-content/uploads/lion.jpg"}],
            "categories": [{"name": "Books"}],
            "tags": [{"name": "Fiction"}],
            "meta_data": [],
        }
    ]

    # When: the WooCommerce adapter cannot extract ISBN from the API product itself.
    records = _run_woocommerce_fetch(products, publisher_name="Two Lines Press")

    # Then: it returns enough canonical source data for the Elixir detail-enrichment worker.
    record = records[0]
    assert record["edition"]["isbn_13"] is None
    assert record["source_uri"] == "https://www.twolinespress.com/shop/books/lion-cross-point/"
    assert record["storefront_url"] == "https://www.twolinespress.com/shop/books/lion-cross-point/"
    assert record["source_product_id"] == "87"
    assert record["source_sku"] == ""
    assert record["publisher"] == "Two Lines Press"
    assert record["missing_fields"] == {"isbn_13": "not present in source record"}


def test_fetch_woocommerce_extracts_first_valid_isbn13_from_sku_text_or_ranges() -> None:
    # Given: WooCommerce SKU text with a valid ISBN-13 embedded among non-ISBN text.
    products = [
        {
            "id": 51,
            "name": "Two Lines SKU Range Book",
            "permalink": "https://www.twolinespress.com/shop/books/range-book/",
            "sku": "PB 978-1-951829-09-4 / EB 978-1-951829-10-0",
            "date_created": "2024-04-02T00:00:00",
            "short_description": "Official product copy.",
            "images": [],
            "categories": [{"name": "Paperback"}],
            "tags": [],
            "meta_data": [],
        }
    ]

    # When: the adapter normalizes the product.
    records = _run_woocommerce_fetch(products, publisher_name="Two Lines Press")

    # Then: it uses the first valid ISBN-13 instead of leaving the record unenriched.
    record = records[0]
    assert record["edition"]["isbn_13"] == "9781951829094"
    assert record["source_sku"] == "9781951829094"
    assert record["source_product_id"] == "51-9781951829094"
