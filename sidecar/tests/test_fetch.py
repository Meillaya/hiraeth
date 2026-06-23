import json
from typing import Any
from unittest.mock import patch
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def _mock_httpx_client(responses: list[tuple[int, dict[str, Any] | list[Any] | str | bytes, dict[str, str]]]):
    """Return a patch target that yields an AsyncClient mock.

    responses: list of (status_code, json_body, headers) tuples.
    Each call to .get() consumes the next response in order.
    """
    class MockResponse:
        def __init__(self, status_code, json_body, headers, content):
            self.status_code = status_code
            self._json = json_body
            self.headers = headers
            self.content = content
            self.text = content.decode("utf-8", "replace")

        def raise_for_status(self):
            if self.status_code >= 400:
                raise Exception(f"HTTP {self.status_code}")

        def json(self):
            return self._json

    class MockClient:
        def __init__(self, responses):
            self._responses = list(responses)
            self._index = 0

        async def get(self, url, **kwargs):
            if self._index >= len(self._responses):
                raise Exception("No more mock responses")
            status_code, json_body, headers = self._responses[self._index]
            self._index += 1
            if isinstance(json_body, bytes):
                content = json_body
            elif isinstance(json_body, str):
                content = json_body.encode("utf-8")
            else:
                content = json.dumps(json_body).encode("utf-8")
            return MockResponse(status_code, json_body, headers, content)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

    def factory(*args, **kwargs):
        return MockClient(responses)

    return patch("httpx.AsyncClient", side_effect=factory)


# ---------------------------------------------------------------------------
# Shopify
# ---------------------------------------------------------------------------

def test_fetch_shopify_basic():
    products = [
        {
            "id": 123,
            "handle": "test-book",
            "title": "Test Book",
            "vendor": "Test Press",
            "published_at": "2024-01-15T00:00:00Z",
            "tags": ["Fiction", "Literature"],
            "body_html": "A great book.",
            "images": [{"src": "https://cdn.example.com/cover.jpg"}],
            "variants": [
                {"id": 456, "sku": "9781234567890", "title": "Paperback"},
            ],
        }
    ]

    mock = _mock_httpx_client([
        (200, {"products": products}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "test_press",
            "config": {
                "api": {"type": "shopify", "endpoint": "https://store.example.com"},
                "source_hosts": ["store.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert data["provider"] == "test_press"
    assert data["status"] == "success"
    assert len(data["records"]) == 1

    record = data["records"][0]
    assert record["source_uri"] == "https://store.example.com/products/test-book"
    assert record["source_product_id"] == "123-456"
    assert record["source_sku"] == "9781234567890"
    assert record["publisher"] == "Test Press"
    assert record["work"]["title"] == "Test Book"
    assert record["work"]["subjects"] == ["Fiction", "Literature"]
    assert record["edition"]["format"] == "paperback"
    assert record["edition"]["published_on"] == "2024-01-15"
    assert record["edition"]["isbn_13"] == "9781234567890"
    assert record["cover"]["source_url"] == "https://cdn.example.com/cover.jpg"
    assert record["description"] == "A great book."
    assert "field_sources" in record


def test_fetch_shopify_pagination():
    page1 = [{"id": 1, "handle": "book-1", "title": "Book 1", "vendor": "P", "published_at": "2024-01-01T00:00:00Z", "tags": [], "body_html": "", "images": [], "variants": [{"id": 1, "sku": "", "title": ""}]}]
    page2 = [{"id": 2, "handle": "book-2", "title": "Book 2", "vendor": "P", "published_at": "2024-01-02T00:00:00Z", "tags": [], "body_html": "", "images": [], "variants": [{"id": 2, "sku": "", "title": ""}]}]

    mock = _mock_httpx_client([
        (200, {"products": page1 * 250}, {}),
        (200, {"products": page2}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "p",
            "config": {
                "api": {"type": "shopify", "endpoint": "https://store.example.com"},
                "source_hosts": ["store.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 251


def test_fetch_shopify_no_variants():
    product = {
        "id": 99,
        "handle": "lonely",
        "title": "Lonely Book",
        "vendor": "V",
        "published_at": "2024-03-01T00:00:00Z",
        "tags": [],
        "body_html": "",
        "images": [],
        "variants": [],
    }

    mock = _mock_httpx_client([
        (200, {"products": [product]}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "v",
            "config": {
                "api": {"type": "shopify", "endpoint": "https://store.example.com"},
                "source_hosts": ["store.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 1
    assert data["records"][0]["source_product_id"] == "99-99"


# ---------------------------------------------------------------------------
# WooCommerce
# ---------------------------------------------------------------------------

def test_fetch_woocommerce_basic():
    products = [
        {
            "id": 101,
            "name": "Woo Book",
            "permalink": "https://shop.example.com/book/woo-book/",
            "sku": "9780987654328",
            "vendor": "Woo Press",
            "date_created": "2024-02-20T00:00:00",
            "short_description": "A woo book.",
            "images": [{"src": "https://shop.example.com/cover.jpg"}],
            "categories": [{"name": "Paperback"}],
            "tags": [{"name": "Fiction"}],
            "meta_data": [{"key": "publication_date", "value": "2024-02-20"}],
        }
    ]

    mock = _mock_httpx_client([
        (200, products, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "woo_press",
            "config": {
                "api": {"type": "woocommerce", "endpoint": "https://shop.example.com"},
                "source_hosts": ["shop.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    assert len(data["records"]) == 1

    record = data["records"][0]
    assert record["source_uri"] == "https://shop.example.com/book/woo-book/"
    assert record["source_sku"] == "9780987654328"
    assert record["edition"]["isbn_13"] == "9780987654328"
    assert record["edition"]["format"] == "paperback"
    assert record["edition"]["published_on"] == "2024-02-20"
    assert record["work"]["subjects"] == ["Fiction"]
    assert record["cover"]["source_url"] == "https://shop.example.com/cover.jpg"


def test_fetch_woocommerce_pagination():
    page1 = [{"id": i, "name": f"B{i}", "permalink": "", "sku": "", "vendor": "", "date_created": "", "short_description": "", "images": [], "categories": [], "tags": [], "meta_data": []} for i in range(100)]
    page2 = [{"id": 100, "name": "Last", "permalink": "", "sku": "", "vendor": "", "date_created": "", "short_description": "", "images": [], "categories": [], "tags": [], "meta_data": []}]

    mock = _mock_httpx_client([
        (200, page1, {}),
        (200, page2, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "p",
            "config": {
                "api": {"type": "woocommerce", "endpoint": "https://shop.example.com"},
                "source_hosts": ["shop.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 101


# ---------------------------------------------------------------------------
# Squarespace
# ---------------------------------------------------------------------------

def test_fetch_squarespace_basic():
    collection = {
        "collection": {
            "items": [
                {
                    "id": "sq-1",
                    "title": "Square Book",
                    "fullUrl": "https://site.example.com/books/square-book",
                    "body": "A square book.",
                    "customContent": {
                        "isbn": "9781111111111",
                        "author": "Alice Author",
                        "format": "hardcover",
                        "publishedOn": "2024-05-01",
                    },
                    "assets": [
                        {"mediaType": "image/jpeg", "absoluteUrl": "https://images.example.com/cover.jpg"},
                    ],
                    "tags": ["Essays"],
                }
            ]
        }
    }

    mock = _mock_httpx_client([
        (200, collection, {}),
        (200, "", {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "square_site",
            "config": {
                "api": {"type": "squarespace", "endpoint": "https://site.example.com/books"},
                "source_hosts": ["site.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    assert len(data["records"]) == 1

    record = data["records"][0]
    assert record["source_uri"] == "https://site.example.com/books/square-book"
    assert record["source_sku"] == "9781111111111"
    assert record["edition"]["isbn_13"] == "9781111111111"
    assert record["edition"]["format"] == "hardcover"
    assert record["edition"]["published_on"] == "2024-05-01"
    assert record["contributors"] == [{"name": "Alice Author", "role": "author"}]
    assert record["cover"]["source_url"] == "https://images.example.com/cover.jpg"
    assert record["work"]["subjects"] == ["Essays"]


def test_fetch_squarespace_flat_items():
    """Some Squarespace JSON responses put items directly under 'items'."""
    body = {
        "items": [
            {
                "id": "sq-2",
                "title": "Flat",
                "fullUrl": "",
                "body": "",
                "customContent": {"author": "Flat Author"},
                "assets": [],
                "tags": [],
            }
        ]
    }

    mock = _mock_httpx_client([
        (200, body, {}),
        (200, "", {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "sq",
            "config": {
                "api": {"type": "squarespace", "endpoint": "https://site.example.com/all-books"},
                "source_hosts": ["site.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 1
    assert data["records"][0]["work"]["title"] == "Flat"


def test_fetch_squarespace_filters_bundles_and_uses_store_item_fields():
    body = {
        "collection": {
            "items": [
                {
                    "id": "bundle-1",
                    "title": "2026 Fiction Bundle",
                    "fullUrl": "/bookstore/2026-bundle",
                    "categories": ["Bundles", "All"],
                    "assetUrl": "https://images.example.com/bundle.png",
                    "structuredContent": {
                        "variants": [
                            {"sku": "2026Bundle", "price": 9000},
                        ],
                        "mainImage": {"assetUrl": "https://images.example.com/bundle-main.png"},
                    },
                },
                {
                    "id": "book-1",
                    "title": "Cathedrals",
                    "fullUrl": "/bookstore/cathedrals",
                    "excerpt": "<h3>Claudia Piñeiro</h3><p>Translated by Frances Riddle</p>",
                    "assetUrl": "https://static1.squarespace.com/static/583cb891/5840506a/book-1/1762952699163/",
                    "structuredContent": {
                        "variants": [
                            {"sku": "9781917260282", "price": 1199},
                        ],
                    },
                    "categories": ["All", "Print"],
                },
                {
                    "id": "book-1-ebook",
                    "title": "Cathedrals (eBook)",
                    "fullUrl": "/bookstore/cathedrals-ebook",
                    "excerpt": "<h3>Claudia Piñeiro</h3><p>Translated by Frances Riddle</p>",
                    "assetUrl": "https://images.squarespace-cdn.com/content/v1/583cb891/cathedrals-ebook.png",
                    "structuredContent": {"productType": 2, "variants": []},
                    "categories": ["All", "Digital"],
                },
                {
                    "id": "placeholder-1",
                    "title": "Placeholder Cover Book",
                    "fullUrl": "/bookstore/placeholder-cover-book",
                    "excerpt": "<h3>Placeholder Author</h3>",
                    "assetUrl": "https://static1.squarespace.com/static/book-cover/",
                    "structuredContent": {
                        "variants": [
                            {"sku": "9781917260992", "price": 1199},
                        ],
                    },
                    "categories": ["All", "Print"],
                },
            ]
        }
    }

    listing_html = """
    <article data-item-id="book-1">
      <img data-src="https://images.squarespace-cdn.com/content/v1/583cb891/cathedrals.jpg" />
    </article>
    <article data-item-id="book-1-ebook">
      <img data-src="https://images.squarespace-cdn.com/content/v1/583cb891/cathedrals-ebook.png" />
    </article>
    <article data-item-id="placeholder-1">
      <img data-src="https://assets.squarespace.com/universal/images-v6/configuration/no-image.png" />
    </article>
    """

    mock = _mock_httpx_client([
        (200, body, {}),
        (200, listing_html, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "charco_press",
            "config": {
                "api": {"type": "squarespace", "endpoint": "https://charcopress.com/bookstore"},
                "source_hosts": ["charcopress.com"],
                "publisher_name": "Charco Press",
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    assert len(data["records"]) == 3

    record = data["records"][0]
    assert record["publisher"] == "Charco Press"
    assert record["source_uri"] == "https://charcopress.com/bookstore/cathedrals"
    assert record["storefront_url"] == "https://charcopress.com/bookstore/cathedrals"
    assert record["source_sku"] == "9781917260282"
    assert record["edition"]["isbn_13"] == "9781917260282"
    assert record["edition"]["format"] == "paperback"
    assert record["cover"]["source_url"] == "https://images.squarespace-cdn.com/content/v1/583cb891/cathedrals.jpg"
    assert "cover" in record["displayed_fields"]
    assert record["description"] == "Claudia Piñeiro Translated by Frances Riddle"
    assert "published_on" not in record["displayed_fields"]

    ebook = data["records"][1]
    assert ebook["work"]["title"] == "Cathedrals"
    assert ebook["edition"]["title"] == "Cathedrals"
    assert ebook["edition"]["format"] == "ebook"
    assert ebook["cover"]["source_url"] == "https://images.squarespace-cdn.com/content/v1/583cb891/cathedrals-ebook.png"

    placeholder = data["records"][2]
    assert placeholder["cover"]["source_url"] == ""
    assert placeholder["no_cover_reason"] == "no usable cover image URL present in source record"
    assert "cover" not in placeholder["displayed_fields"]


# ---------------------------------------------------------------------------
# WordPress
# ---------------------------------------------------------------------------

def test_fetch_wordpress_basic():
    posts = [
        {
            "id": 42,
            "link": "https://blog.example.com/book/wp-book/",
            "title": {"rendered": "WP Book"},
            "content": {"rendered": "Content."},
            "excerpt": {"rendered": "Excerpt."},
            "date": "2024-06-10T00:00:00",
            "meta": [{"key": "isbn", "value": "9782222222222"}],
            "tags": [{"name": "Poetry"}],
            "featured_media": 7,
        }
    ]

    mock = _mock_httpx_client([
        (200, posts, {"X-WP-TotalPages": "1"}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "wp_site",
            "config": {
                "api": {"type": "wordpress", "endpoint": "https://blog.example.com"},
                "source_hosts": ["blog.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    assert len(data["records"]) == 1

    record = data["records"][0]
    assert record["source_uri"] == "https://blog.example.com/book/wp-book/"
    assert record["work"]["title"] == "WP Book"
    assert record["edition"]["isbn_13"] == "9782222222222"
    assert record["edition"]["format"] == "paperback"
    assert record["edition"]["published_on"] == "2024-06-10"
    assert record["description"] == "Excerpt."
    assert record["cover"]["source_url"] == "https://blog.example.com/wp-json/wp/v2/media/7"
    assert record["work"]["subjects"] == ["Poetry"]


def test_fetch_wordpress_pagination():
    page1 = [{"id": i, "link": "", "title": {"rendered": f"P{i}"}, "content": {"rendered": ""}, "excerpt": {"rendered": ""}, "date": "", "meta": [], "tags": [], "featured_media": 0} for i in range(100)]
    page2 = [{"id": 100, "link": "", "title": {"rendered": "Last"}, "content": {"rendered": ""}, "excerpt": {"rendered": ""}, "date": "", "meta": [], "tags": [], "featured_media": 0}]

    mock = _mock_httpx_client([
        (200, page1, {"X-WP-TotalPages": "2"}),
        (200, page2, {"X-WP-TotalPages": "2"}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "wp",
            "config": {
                "api": {"type": "wordpress", "endpoint": "https://blog.example.com"},
                "source_hosts": ["blog.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 101


# ---------------------------------------------------------------------------
# Router validation
# ---------------------------------------------------------------------------

def test_fetch_missing_api_type():
    response = client.post("/fetch/", json={
        "provider": "x",
        "config": {},
    })
    assert response.status_code == 400
    assert "Missing config.api.type" in response.json()["detail"]


def test_fetch_unsupported_api_type():
    response = client.post("/fetch/", json={
        "provider": "x",
        "config": {"api": {"type": "unknown"}},
    })
    assert response.status_code == 400
    assert "Unsupported api.type" in response.json()["detail"]


def test_fetch_rejects_endpoint_host_outside_source_hosts():
    response = client.post("/fetch/", json={
        "provider": "x",
        "config": {
            "api": {"type": "shopify", "endpoint": "https://evil.example.com"},
            "source_hosts": ["store.example.com"],
        },
    })

    assert response.status_code == 400
    assert "host must be listed in source_hosts" in response.json()["detail"]


def test_fetch_rejects_private_endpoint_hosts():
    response = client.post("/fetch/", json={
        "provider": "x",
        "config": {
            "api": {"type": "shopify", "endpoint": "https://127.0.0.1"},
            "source_hosts": ["127.0.0.1"],
        },
    })

    assert response.status_code == 400
    assert "must not be private" in response.json()["detail"]


def test_fetch_rejects_endpoint_userinfo():
    response = client.post("/fetch/", json={
        "provider": "x",
        "config": {
            "api": {"type": "shopify", "endpoint": "https://user:pass@store.example.com"},
            "source_hosts": ["store.example.com"],
        },
    })

    assert response.status_code == 400
    assert "must not include userinfo" in response.json()["detail"]


# ---------------------------------------------------------------------------
# Rate limiting / max_bytes
# ---------------------------------------------------------------------------

def test_fetch_shopify_max_bytes():
    """If a single response exceeds max_bytes, fetching stops."""
    huge_product = {"id": 1, "handle": "h", "title": "H", "vendor": "V", "published_at": "", "tags": [], "body_html": "x" * 100, "images": [], "variants": [{"id": 1, "sku": "", "title": ""}]}

    mock = _mock_httpx_client([
        (200, {"products": [huge_product]}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "p",
            "config": {
                "api": {"type": "shopify", "endpoint": "https://store.example.com"},
                "source_hosts": ["store.example.com"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert data["records"] == []


def test_fetch_shopify_filters_bundles_and_non_books():
    book_product = {
        "id": 1, "handle": "real-book", "title": "A Real Book",
        "vendor": "Deep Vellum", "product_type": "Books",
        "published_at": "", "tags": ["fiction"], "body_html": "",
        "images": [], "variants": [{"id": 1, "sku": "", "title": ""}],
    }
    bundle_product = {
        "id": 2, "handle": "subscriber-bundle", "title": "Subscriber Bundle",
        "vendor": "Deep Vellum", "product_type": "Bundles",
        "published_at": "", "tags": ["bundle"], "body_html": "",
        "images": [], "variants": [{"id": 2, "sku": "", "title": ""}],
    }
    gift_card_product = {
        "id": 3, "handle": "gift-card", "title": "Gift Card",
        "vendor": "Deep Vellum", "product_type": "Gift Card",
        "published_at": "", "tags": [], "body_html": "",
        "images": [], "variants": [{"id": 3, "sku": "", "title": ""}],
    }
    sideline_product = {
        "id": 4, "handle": "tote-bag", "title": "Tote Bag",
        "vendor": "Deep Vellum", "product_type": "Sideline",
        "published_at": "", "tags": ["merch"], "body_html": "",
        "images": [], "variants": [{"id": 4, "sku": "", "title": ""}],
    }

    mock = _mock_httpx_client([
        (200, {"products": [book_product, bundle_product, gift_card_product, sideline_product]}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "deep_vellum_official_store",
            "config": {
                "api": {"type": "shopify", "endpoint": "https://store.deepvellum.org"},
                "source_hosts": ["store.deepvellum.org"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10485760},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 1
    assert data["records"][0]["work"]["title"] == "A Real Book"


def test_fetch_shopify_filters_by_allowed_vendors():
    dv_book = {
        "id": 1, "handle": "dv-book", "title": "Deep Vellum Book",
        "vendor": "Deep Vellum", "product_type": "Books",
        "published_at": "", "tags": [], "body_html": "",
        "images": [], "variants": [{"id": 1, "sku": "", "title": ""}],
    }
    phoneme_book = {
        "id": 2, "handle": "phoneme-book", "title": "Phoneme Book",
        "vendor": "Phoneme", "product_type": "Books",
        "published_at": "", "tags": [], "body_html": "",
        "images": [], "variants": [{"id": 2, "sku": "", "title": ""}],
    }

    mock = _mock_httpx_client([
        (200, {"products": [dv_book, phoneme_book]}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "deep_vellum_official_store",
            "config": {
                "api": {
                    "type": "shopify",
                    "endpoint": "https://store.deepvellum.org",
                    "allowed_vendors": ["Deep Vellum", "Deep Vellum Publishing"],
                },
                "source_hosts": ["store.deepvellum.org"],
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 1
    assert data["records"][0]["work"]["title"] == "Deep Vellum Book"
    assert data["records"][0]["publisher"] == "Deep Vellum"


def test_fetch_shopify_extracts_book_metadata_from_body_html():
    products = [
        {
            "id": 1,
            "handle": "life-before-dolphins",
            "title": "Life Before Dolphins",
            "vendor": "CHPbeta",
            "product_type": "Book",
            "tags": ["fiction"],
            "body_html": "Novel by Kirmen Uribe January 26, 2027 • 978-1-56689-773-0",
            "images": [{"src": "https://cdn.example.com/dolphins.jpg"}],
            "variants": [{"id": 11, "sku": None, "title": "Paperback"}],
        },
        {
            "id": 2,
            "handle": "the-man-without-illness",
            "title": "The Man Without Illness",
            "vendor": "Arnon Grunberg",
            "product_type": "paperback",
            "tags": ["books"],
            "body_html": "February 24, 2027 novel | pb | 978-1-960385-62-8",
            "images": [{"src": "https://cdn.example.com/man.jpg"}],
            "variants": [
                {"id": 22, "sku": "", "title": "Paperback"},
                {"id": 23, "sku": "", "title": "Ebook"},
            ],
        },
        {
            "id": 3,
            "handle": "unknown-book",
            "title": "Unknown Book",
            "vendor": "CHPbeta",
            "product_type": "Book",
            "tags": ["fiction"],
            "body_html": "A book without contributor metadata.",
            "images": [{"src": "https://cdn.example.com/unknown.jpg"}],
            "variants": [{"id": 33, "sku": "", "title": "Paperback"}],
        },
    ]

    mock = _mock_httpx_client([
        (200, {"products": products}, {}),
    ])

    with mock:
        response = client.post("/fetch/", json={
            "provider": "publisher",
            "config": {
                "api": {"type": "shopify", "endpoint": "https://store.example.com"},
                "source_hosts": ["store.example.com"],
                "publisher_name": "Coffee House Press",
                "rate_limit": {"min_delay_ms": 0, "max_bytes": 10_000_000},
            },
        })

    assert response.status_code == 200
    data = response.json()
    assert len(data["records"]) == 2

    coffee_record, open_letter_record = data["records"]
    assert coffee_record["publisher"] == "Coffee House Press"
    assert open_letter_record["publisher"] == "Coffee House Press"
    assert coffee_record["contributors"] == [{"name": "Kirmen Uribe", "role": "author"}]
    assert coffee_record["edition"]["isbn_13"] == "9781566897730"
    assert open_letter_record["contributors"] == [{"name": "Arnon Grunberg", "role": "author"}]
    assert open_letter_record["edition"]["isbn_13"] == "9781960385628"
