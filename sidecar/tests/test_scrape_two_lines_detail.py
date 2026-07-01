"""Two Lines detail scrape router tests."""

from pathlib import Path
from typing import Final
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.spiders.deep_vellum_stealthy import StealthyFetcher

client = TestClient(app)
FIXTURES_DIR: Final = Path(__file__).parent / "fixtures"


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


def test_scrape_detail_endpoint_returns_two_lines_enrichment(monkeypatch) -> None:
    # Given: an allowlisted Two Lines product detail URL and deterministic detail HTML.
    async def fake_fetch_async(url: str, **_kwargs):
        return type("FakeResponse", (), {"url": url, "text": _load_fixture("two_lines_detail_lion_cross_point.html")})()

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    # When: the generic detail endpoint is called for the Two Lines provider.
    response = client.post(
        "/scrape/detail",
        json={
            "vendor": "two_lines_press_official_store",
            "url": "https://www.twolinespress.com/shop/books/lion-cross-point/",
        },
    )

    # Then: factual enrichment fields are extracted without using a global API.
    assert response.status_code == 200
    data = response.json()
    assert data["vendor"] == "two_lines_press_official_store"
    assert data["source_uri"] == "https://www.twolinespress.com/shop/books/lion-cross-point/"
    assert data["contributors"] == [{"name": "Angus Turvill", "role": "translator"}]
    assert data["isbn_13"] == "9781931883702"
    assert data["published_on"] == "2018-03-13"
    assert data["cover"]["source_url"] == "https://www.twolinespress.com/wp-content/uploads/2018/03/lion-cross-point.jpg"
    assert "haunting coming-of-age" in data["description"]


def test_scrape_detail_endpoint_rejects_two_lines_disallowed_host_before_fetch() -> None:
    # Given: a Two Lines detail request targeting a non-allowlisted host.
    with patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async:
        # When: the endpoint validates the request.
        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "two_lines_press_official_store",
                "url": "https://evil.example/shop/books/lion-cross-point/",
            },
        )

    # Then: it rejects before network fetch.
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "invalid_host"
    assert response.json()["detail"]["message"] == "Unsupported detail URL host"
    fetch_async.assert_not_awaited()


def test_scrape_detail_endpoint_rejects_two_lines_cart_paths_before_fetch() -> None:
    # Given: a valid host but a cart/account/checkout-style path.
    with patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async:
        # When: the endpoint validates the request.
        response = client.post(
            "/scrape/detail",
            json={
                "vendor": "two_lines_press_official_store",
                "url": "https://www.twolinespress.com/cart/",
            },
        )

    # Then: it rejects before network fetch.
    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "invalid_host"
    assert response.json()["detail"]["message"] == "Detail URL must target a Two Lines book"
    fetch_async.assert_not_awaited()
