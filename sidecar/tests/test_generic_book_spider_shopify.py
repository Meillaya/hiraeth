from unittest.mock import AsyncMock, patch

from scrapling.spiders import Response

from app.spiders.generic_book_spider import GenericBookSpider


def _make_response(url: str, html: str) -> Response:
    return Response(url, html, 200, "OK", {}, {}, {})


def test_shopify_collection_cards_resolve_item_urls():
    html = """<html><body>
        <product-grid-item aria-label="Yñiga">
          <a href="/products/yniga" data-grid-link aria-label="Yñiga">
            <img src="//coffeehousepress.org/cdn/shop/files/Yniga.jpg?v=1" />
          </a>
        </product-grid-item>
        <product-grid-item>
          <a href="/products/untitled"><img src="/cdn/shop/files/skip.jpg" /></a>
        </product-grid-item>
    </body></html>"""
    mock_response = _make_response("https://coffeehousepress.org/collections/shop", html)

    spider = GenericBookSpider(
        config={
            "start_urls": ["https://coffeehousepress.org/collections/shop"],
            "provider": "coffee_house_press",
            "selectors": {
                "item": "product-grid-item",
                "title": "::attr(aria-label)",
                "source_uri": "a::attr(href)",
                "cover": "img::attr(src)",
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
    record = records[0]
    assert record["work"]["title"] == "Yñiga"
    assert record["source_uri"] == "https://coffeehousepress.org/products/yniga"
    assert record["storefront_url"] == "https://coffeehousepress.org/products/yniga"
    assert record["field_sources"]["title"]["source_uri"] == "https://coffeehousepress.org/products/yniga"
    assert record["cover"]["source_url"] == "https://coffeehousepress.org/cdn/shop/files/Yniga.jpg?v=1"
