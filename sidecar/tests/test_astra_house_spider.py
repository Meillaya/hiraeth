"""Astra House-only scrape route tests."""

from pathlib import Path
from typing import Final
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.spiders.deep_vellum_stealthy import StealthyFetcher

client = TestClient(app)
FIXTURES_DIR: Final = Path(__file__).parent / "fixtures"
ASTRA_IMPRINT_URL: Final = "https://astrapublishinghouse.com/imprints/astra-house/"


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


def _ackermann_detail() -> str:
    return """
    <html><body><main>
      <h1 class="product_title">Ackermann</h1>
      <p class="author">by Dymphna Cusack</p>
      <span class="isbn">ISBN: 9781662603754</span>
      <span class="pubdate">Publication Date: 2024-09-10</span>
      <select class="select-format">
        <option data-url="https://astrapublishinghouse.com/product/ackermann-9781662603754/">Trade Paperback</option>
      </select>
      <img class="cover" src="https://images.penguinrandomhouse.com/cover/700jpg/9781662603754" />
      <div class="description"><p>An Astra House reissue fixture.</p></div>
    </main></body></html>
    """


def test_scrape_astra_house_imprint_groups_sibling_format_pages(monkeypatch) -> None:
    # Given: the Astra House imprint page and product detail pages returned by the sidecar fetcher.
    fetched_urls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs):
        fetched_urls.append(url)
        if url == ASTRA_IMPRINT_URL:
            text = _load_fixture("astra_house_imprint.html")
        elif "early-sobrieties" in url:
            text = _load_fixture("astra_house_detail_early_sobrieties.html")
        elif "ackermann" in url:
            text = _ackermann_detail()
        else:
            raise AssertionError(f"unexpected Astra fetch URL: {url}")
        return type("FakeResponse", (), {"url": url, "text": text})()

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    # When: the scrape endpoint is run for the Astra House provider.
    response = client.post(
        "/scrape/",
        json={
            "provider": "astra_house_official_store",
            "config": {"start_urls": [ASTRA_IMPRINT_URL], "rate_limit": {"min_delay_ms": 0}},
        },
    )

    # Then: only the imprint page is used as the seed and sibling format URLs share one work title.
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    records = data["records"]
    assert len(records) == 3
    assert fetched_urls[0] == ASTRA_IMPRINT_URL
    assert "https://astrapublishinghouse.com/" not in fetched_urls

    early_records = [record for record in records if record["work"]["title"] == "Early Sobrieties"]
    assert [record["edition"]["isbn_13"] for record in early_records] == ["9781662602245", "9781662602252"]
    assert [record["edition"]["format"] for record in early_records] == ["paperback", "ebook"]
    assert {record["source_uri"] for record in early_records} == {
        "https://astrapublishinghouse.com/product/early-sobrieties-9781662602245/",
        "https://astrapublishinghouse.com/product/early-sobrieties-9781662602252/",
    }
    assert all(record["cover"]["source_url"].startswith("https://images.penguinrandomhouse.com/") for record in records)


def test_scrape_astra_house_rejects_global_astra_seed_before_fetch() -> None:
    # Given: a global Astra URL rather than the Astra House imprint page.
    with patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async:
        # When: the scrape endpoint validates the configured seed.
        response = client.post(
            "/scrape/",
            json={
                "provider": "astra_house_official_store",
                "config": {"start_urls": ["https://astrapublishinghouse.com/"]},
            },
        )

    # Then: it fails closed before fetching a global source.
    assert response.status_code == 422
    assert "Astra House catalog URL is not allowlisted" in response.json()["detail"]
    fetch_async.assert_not_awaited()


def test_scrape_astra_house_excludes_non_product_links(monkeypatch) -> None:
    # Given: an imprint fixture containing a non-product Astra link mixed with one valid book.
    listing = """
    <html><body><main class="imprint-products">
      <article><a href="https://astrapublishinghouse.com/imprints/minedition/">Other imprint</a></article>
      <article><a href="https://astrapublishinghouse.com/product/early-sobrieties-9781662602245/">Early Sobrieties</a></article>
    </main></body></html>
    """
    fetched_urls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs):
        fetched_urls.append(url)
        text = listing if url == ASTRA_IMPRINT_URL else _load_fixture("astra_house_detail_early_sobrieties.html")
        return type("FakeResponse", (), {"url": url, "text": text})()

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    # When: Astra House scrape runs.
    response = client.post(
        "/scrape/",
        json={"provider": "astra_house_official_store", "config": {"start_urls": [ASTRA_IMPRINT_URL]}},
    )

    # Then: non-product links are not fetched or emitted.
    assert response.status_code == 200
    assert all("/imprints/minedition" not in url for url in fetched_urls)
    assert len(response.json()["records"]) == 2
