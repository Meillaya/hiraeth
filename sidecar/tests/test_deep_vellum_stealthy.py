"""Tests for the manual async Deep Vellum StealthyFetcher spider."""

from dataclasses import dataclass
from pathlib import Path
from typing import Final

import anyio
import pytest

from app.models import BookRecord
from app.spiders.deep_vellum_stealthy import (
    DeepVellumStealthySpider,
    ResponseTooLargeError,
    StealthyFetcher,
)

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


def test_scrape_catalog_enriches_allowed_products(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given rendered fixtures, when scraping, then records match importer shape."""
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

    records = anyio.run(DeepVellumStealthySpider().scrape_catalog, {})

    assert calls[0] == CATALOG_URL
    assert RILKE_URL in calls
    assert BRAZILLIONAIRES_URL in calls
    assert "https://store.deepvellum.org/products/phoneme-book" not in calls
    assert len(records) == 2
    for record in records:
        _ = BookRecord(**record)
        assert record["provider"] == "deep_vellum_official_store"
        assert record["publisher"] in {"Deep Vellum", "Deep Vellum Publishing"}
        assert record["curation"]["status"] == "approved"
        assert record["edition"]["published_on"] in {"2015-03-24", "2016-07-12"}
        assert record["storefront_url"] == record["source_uri"]
        assert set(record["displayed_fields"]).issubset(record["field_sources"])
        assert record["cover"]["cache_policy"] == "cache_allowed"
        assert "prompt:" not in record.get("description", "")


def test_scrape_catalog_rejects_unsafe_catalog_url_before_fetch(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given metadata URL config, when scraping, then no fetch is attempted."""
    calls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text="")

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    with pytest.raises(ValueError, match="Unsupported Deep Vellum catalog URL"):
        anyio.run(
            DeepVellumStealthySpider().scrape_catalog,
            {"catalog_url": "http://169.254.169.254/latest/meta-data/"},
        )

    assert calls == []


def test_scrape_catalog_rejects_unsafe_start_url_before_fetch(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given metadata start URL config, when scraping, then no fetch is attempted."""
    calls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text="")

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    with pytest.raises(ValueError, match="Unsupported Deep Vellum catalog URL"):
        anyio.run(
            DeepVellumStealthySpider().scrape_catalog,
            {"start_urls": ["http://169.254.169.254/latest/meta-data/"]},
        )

    assert calls == []


def test_vendor_not_in_allowlist_is_dropped(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given a non-Deep-Vellum card, when scraping, then no detail fetch occurs."""
    calls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text=_load_fixture("deep_vellum_stealthy_vendor_only_catalog.html"))

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = anyio.run(DeepVellumStealthySpider().scrape_catalog, {})

    assert records == []
    assert calls == [CATALOG_URL]


def test_partial_detail_without_isbn_or_cover_is_validation_friendly(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given missing ISBN and cover, when scraping, then missing fields are explained."""
    calls: list[str] = []
    fixtures = {CATALOG_URL: "deep_vellum_stealthy_partial_catalog.html", PARTIAL_URL: "deep_vellum_stealthy_detail_partial.html"}

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text=_load_fixture(fixtures[url]))

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = anyio.run(DeepVellumStealthySpider().scrape_catalog, {})

    assert calls == [CATALOG_URL, PARTIAL_URL]
    assert len(records) == 1
    record = records[0]
    _ = BookRecord(**record)
    assert record["work"]["title"] == "Nameless City"
    assert record["contributors"] == [{"name": "Example Author", "role": "author"}]
    assert record["edition"]["isbn_13"] is None
    assert record["edition"]["published_on"] == "2024-05-01"
    assert record["missing_fields"] == {"isbn_13": "not present in source record"}
    assert record["cover"]["source_url"] is None
    assert record["no_cover_reason"] == "detail_page_missing_cover"
    assert "isbn_13" not in record["displayed_fields"]
    assert "cover" not in record["displayed_fields"]


def test_detail_fixture_extracts_enrichment_without_live_network(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given a detail URL, when fetched via the seam, then only fixture data is parsed."""
    calls: list[str] = []

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        calls.append(url)
        return FakeStealthyResponse(url=url, text=_load_fixture("deep_vellum_stealthy_detail_rilke.html"))

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    response = anyio.run(StealthyFetcher.fetch_async, RILKE_URL)
    detail = DeepVellumStealthySpider._parse_detail(response.text)
    contributors = DeepVellumStealthySpider._extract_contributors(detail.description)

    assert calls == [RILKE_URL]
    assert contributors == [{"name": "Angélica Freitas", "role": "author"}, {"name": "Hilary Kaplan", "role": "translator"}]
    assert DeepVellumStealthySpider._extract_isbn(detail.description) == "9781939419545"
    assert DeepVellumStealthySpider._extract_publication_date(detail.description) == "2015-03-24"
    assert detail.cover_url == "https://cdn.shopify.com/deep-vellum/rilke-detail.jpg"


def test_manifest_rate_limit_controls_concurrency(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given manifest concurrency one, when details fetch, then fetches do not overlap."""
    active = 0
    max_active = 0

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        nonlocal active, max_active
        if url == CATALOG_URL:
            return FakeStealthyResponse(url=url, text=_load_fixture("deep_vellum_stealthy_catalog.html"))
        active += 1
        max_active = max(max_active, active)
        await anyio.sleep(0)
        active -= 1
        fixture = "deep_vellum_stealthy_detail_rilke.html" if url == RILKE_URL else "deep_vellum_stealthy_detail_brazillionaires.html"
        return FakeStealthyResponse(url=url, text=_load_fixture(fixture))

    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = anyio.run(DeepVellumStealthySpider().scrape_catalog, {"rate_limit": {"max_concurrency": 1}})

    assert len(records) == 2
    assert max_active == 1


def test_manifest_delay_and_max_bytes_are_enforced(monkeypatch: pytest.MonkeyPatch) -> None:
    """Given manifest delay and byte cap, when scraping, then both controls are applied."""
    sleeps: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        sleeps.append(seconds)

    async def fake_fetch_async(url: str, **_kwargs) -> FakeStealthyResponse:
        fixture = "deep_vellum_stealthy_catalog.html" if url == CATALOG_URL else "deep_vellum_stealthy_detail_rilke.html"
        return FakeStealthyResponse(url=url, text=_load_fixture(fixture))

    monkeypatch.setattr("app.spiders.deep_vellum_stealthy.anyio.sleep", fake_sleep)
    monkeypatch.setattr(StealthyFetcher, "fetch_async", fake_fetch_async)

    records = anyio.run(
        DeepVellumStealthySpider().scrape_catalog,
        {"rate_limit": {"max_concurrency": 1, "min_delay_ms": 250, "max_bytes": 1_000_000}},
    )

    assert records
    assert sleeps == [0.25, 0.25]
    with pytest.raises(ResponseTooLargeError):
        anyio.run(DeepVellumStealthySpider().scrape_catalog, {"rate_limit": {"max_bytes": 10}})
