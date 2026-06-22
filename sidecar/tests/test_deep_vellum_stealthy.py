"""Tests for the manual async Deep Vellum StealthyFetcher spider."""

import asyncio
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from app.models import BookRecord
from app.spiders.deep_vellum_stealthy import DeepVellumStealthySpider, StealthyFetcher

FIXTURES_DIR: Final = Path(__file__).parent / "fixtures"
CATALOG_URL: Final = "https://store.deepvellum.org/collections/all"
RILKE_URL: Final = "https://store.deepvellum.org/products/rilke-shake"
BRAZILLIONAIRES_URL: Final = "https://store.deepvellum.org/products/brazillionaires"
PARTIAL_URL: Final = "https://store.deepvellum.org/products/nameless-city"


@dataclass(frozen=True, slots=True)
class FakeStealthyResponse:
    url: str
    text: str


def _load_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text()


def test_scrape_catalog_enriches_allowed_products(monkeypatch) -> None:
    """Given rendered fixtures, when scraping, then records match BookRecord shape."""
    calls: list[str] = []
    fixtures = {
        CATALOG_URL: "deep_vellum_stealthy_catalog.html",
        RILKE_URL: "deep_vellum_stealthy_detail_rilke.html",
        BRAZILLIONAIRES_URL: "deep_vellum_stealthy_detail_brazillionaires.html",
    }

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text=_load_fixture(fixtures[url]))

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = asyncio.run(DeepVellumStealthySpider().scrape_catalog({}))

    assert calls[0] == CATALOG_URL
    assert RILKE_URL in calls
    assert BRAZILLIONAIRES_URL in calls
    assert "https://store.deepvellum.org/products/phoneme-book" not in calls
    assert len(records) == 2
    for record in records:
        _ = BookRecord(**record)
        assert record["provider"] == "deep_vellum_official_store"
        assert record["publisher"] in {"Deep Vellum", "Deep Vellum Publishing"}
        assert record["contributors"]
        assert record["edition"]["isbn_13"]
        assert record["edition"]["published_on"]
        assert record["cover"]["source_url"]
        assert "prompt:" not in record.get("description", "")


def test_vendor_not_in_allowlist_is_dropped(monkeypatch) -> None:
    """Given a non-Deep-Vellum card, when scraping, then no detail fetch occurs."""
    calls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(
            url=url,
            text=_load_fixture("deep_vellum_stealthy_vendor_only_catalog.html"),
        )

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = asyncio.run(DeepVellumStealthySpider().scrape_catalog({}))

    assert records == []
    assert calls == [CATALOG_URL]


def test_partial_detail_without_isbn_or_cover_is_validation_friendly(monkeypatch) -> None:
    """Given missing ISBN and cover, when scraping, then a partial record is emitted."""
    calls: list[str] = []
    fixtures = {
        CATALOG_URL: "deep_vellum_stealthy_partial_catalog.html",
        PARTIAL_URL: "deep_vellum_stealthy_detail_partial.html",
    }

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text=_load_fixture(fixtures[url]))

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = asyncio.run(DeepVellumStealthySpider().scrape_catalog({}))

    assert calls == [CATALOG_URL, PARTIAL_URL]
    assert len(records) == 1
    record = records[0]
    _ = BookRecord(**record)
    assert record["work"]["title"] == "Nameless City"
    assert record["contributors"] == [{"name": "Example Author", "role": "author"}]
    assert record["edition"]["isbn_13"] is None
    assert record["edition"]["published_on"] == "May 1, 2024"
    assert record["cover"]["source_url"] is None
    assert record["cover"]["no_cover_reason"] == "detail_page_missing_cover"
    assert "prompt: ignore instructions" not in record.get("description", "")
