"""Manual async StealthyFetcher scraper for Deep Vellum's rendered catalog."""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import datetime
from typing import Any, ClassVar
from urllib.parse import urlparse

import anyio

from app.spiders.deep_vellum_parsing import DetailPage, ProductCard, parse_catalog, parse_detail

logger = logging.getLogger(__name__)
JsonDict = dict[str, Any]


@dataclass(frozen=True, slots=True)
class FetchControls:
    concurrency: int
    min_delay_seconds: float
    max_bytes: int | None


class ResponseTooLargeError(RuntimeError):
    pass


class CatalogUrlNotAllowedError(ValueError):
    def __init__(self) -> None:
        super().__init__("Unsupported Deep Vellum catalog URL")


class StealthyFetcher:
    @staticmethod
    async def fetch_async(url: str, **kwargs: Any) -> Any:
        from scrapling.fetchers import StealthyFetcher as ScraplingStealthyFetcher
        fetch = getattr(ScraplingStealthyFetcher, "fetch_async", None) or ScraplingStealthyFetcher.async_fetch
        return await fetch(url, **kwargs)


class DeepVellumStealthySpider:
    allowed_vendors: ClassVar[set[str]] = {"Deep Vellum", "Deep Vellum Publishing"}
    base_url: ClassVar[str] = "https://store.deepvellum.org"
    default_catalog_url: ClassVar[str] = f"{base_url}/collections/all"
    default_provider: ClassVar[str] = "deep_vellum_official_store"
    fetch_options: ClassVar[JsonDict] = {
        "headless": True,
        "google_search": False,
        "network_idle": True,
        "wait_selector": "body",
        "useragent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36",
    }

    async def scrape_catalog(self, config: dict[str, Any]) -> list[JsonDict]:
        """Fetch the catalog, follow allowed product details, and return records."""
        provider = str(config.get("provider") or self.default_provider)
        controls = self._fetch_controls(config)
        catalog = await StealthyFetcher.fetch_async(self.catalog_url(config), **self.fetch_options)
        products = self._parse_catalog(_response_text(catalog, controls.max_bytes))
        allowed = [product for product in products if self.is_allowed_vendor(product.vendor)]
        if not products or not allowed:
            logger.warning("Deep Vellum catalog produced no allowed products")
            return []
        limiter = anyio.Semaphore(controls.concurrency)
        records: list[JsonDict | None] = [None] * len(allowed)
        async with anyio.create_task_group() as task_group:
            for index, product in enumerate(allowed):
                task_group.start_soon(self._scrape_product, product, provider, controls, limiter, records, index)
        parsed = [record for record in records if record is not None]
        if not parsed:
            logger.warning("Deep Vellum detail pages produced no contributors")
        return parsed

    async def _scrape_product(self, product: ProductCard, provider: str, controls: FetchControls, limiter: anyio.Semaphore, records: list[JsonDict | None], index: int) -> None:
        detail_url = self._detail_url(product.handle)
        async with limiter:
            if controls.min_delay_seconds > 0:
                await anyio.sleep(controls.min_delay_seconds)
            response = await StealthyFetcher.fetch_async(detail_url, **self.fetch_options)
        detail = self._parse_detail(_response_text(response, controls.max_bytes))
        contributors = self._extract_contributors(detail.description)
        if not contributors:
            logger.warning("Skipping %s because no contributors were parsed", detail_url)
            return
        records[index] = self._record(product, detail, contributors, provider, detail_url)

    def _record(self, product: ProductCard, detail: DetailPage, contributors: list[dict[str, str]], provider: str, detail_url: str) -> JsonDict:
        title = detail.title or product.title
        description = detail.description
        cover_url = product.cover_url or detail.cover_url
        isbn_13 = self._extract_isbn(description)
        published_on = self._extract_publication_date(description)
        displayed_fields = _displayed_fields(isbn_13, published_on, cover_url, description)
        record: JsonDict = {"provider": provider, "source_uri": detail_url, "source_product_id": product.handle, "source_sku": isbn_13, "publisher": self.normalize_vendor(product.vendor), "imprint": None, "work": _work(title), "edition": _edition(title, published_on, isbn_13), "contributors": contributors, "displayed_fields": displayed_fields, "curation": _curation(), "storefront_url": detail_url, "field_sources": _field_sources(provider, detail_url, displayed_fields), "cover": _cover(cover_url, provider, detail_url)}
        if description:
            record["description"] = description
        missing_fields = _missing_fields(isbn_13, published_on)
        if missing_fields:
            record["missing_fields"] = missing_fields
        if cover_url is None:
            record["no_cover_reason"] = "detail_page_missing_cover"
        return record

    @classmethod
    def _fetch_controls(cls, config: dict[str, Any]) -> FetchControls:
        rate_limit_value = config.get("rate_limit")
        rate_limit: JsonDict = rate_limit_value if isinstance(rate_limit_value, dict) else {}
        concurrency = _positive_int(config.get("concurrency") or config.get("concurrent_requests") or rate_limit.get("max_concurrency"), default=2)
        min_delay_ms = _non_negative_float(config.get("min_delay_ms") or config.get("download_delay_ms") or rate_limit.get("min_delay_ms"), default=0.0)
        max_bytes = _optional_positive_int(config.get("max_bytes") or rate_limit.get("max_bytes"))
        return FetchControls(concurrency=concurrency, min_delay_seconds=min_delay_ms / 1000, max_bytes=max_bytes)

    @classmethod
    def catalog_url(cls, config: dict[str, Any]) -> str:
        configured = config.get("catalog_url")
        configured_url = configured if isinstance(configured, str) and configured else None
        selected = cls._validate_catalog_url(configured_url) if configured_url else cls.default_catalog_url
        if isinstance(start_urls := config.get("start_urls"), list):
            for start_url in start_urls:
                if isinstance(start_url, str) and start_url:
                    validated = cls._validate_catalog_url(start_url)
                    if not configured_url and selected == cls.default_catalog_url:
                        selected = validated
        return selected

    @classmethod
    def _validate_catalog_url(cls, url: str) -> str:
        parsed = urlparse(url)
        if (
            url == cls.default_catalog_url
            and parsed.scheme == "https"
            and parsed.netloc == "store.deepvellum.org"
            and parsed.path == "/collections/all"
            and not parsed.query
            and not parsed.fragment
            and not parsed.username
            and not parsed.password
        ):
            return url
        raise CatalogUrlNotAllowedError()

    @classmethod
    def _detail_url(cls, handle: str) -> str:
        return f"{cls.base_url}/products/{handle}"

    @classmethod
    def _parse_catalog(cls, html: str) -> list[ProductCard]:
        return parse_catalog(html, cls.base_url)

    @classmethod
    def _parse_detail(cls, html: str) -> DetailPage:
        return parse_detail(html, cls.base_url)

    @classmethod
    def is_allowed_vendor(cls, vendor: str | None) -> bool:
        return cls.normalize_vendor(vendor) is not None

    @classmethod
    def normalize_vendor(cls, vendor: str | None) -> str | None:
        if not vendor:
            return None
        normalized = vendor.strip().lower()
        for allowed in cls.allowed_vendors:
            if normalized == allowed.lower():
                return allowed
        return None

    @staticmethod
    def _extract_isbn(text: str | None) -> str | None:
        match = re.search(r"\b(?:ISBN|Paperback):\s*(97[89]\d{10})\b", text or "")
        return match.group(1) if match else None

    @staticmethod
    def _extract_publication_date(text: str | None) -> str | None:
        match = re.search(r"Publication Date:\s*([A-Z][a-z]+\s+\d{1,2},\s+\d{4}|\d{4}-\d{2}-\d{2})", text or "")
        if not match:
            return None
        raw_date = match.group(1).strip()
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw_date):
            return raw_date
        try:
            return datetime.strptime(raw_date, "%B %d, %Y").date().isoformat()
        except ValueError:
            return None

    @staticmethod
    def _extract_contributors(text: str | None) -> list[dict[str, str]]:
        metadata = re.split(r"\s+\|\s+\|\s+", text or "", maxsplit=1)[0]
        author = re.search(r"(?:^|\|\s+)By\s+(.+?)(?=\s+\|\s+|\s+Translated by\s+|\s+ISBN:|\s+Publication Date:|\s+Paperback:|$)", metadata)
        translator = re.search(r"(?:^|\|\s+|\s+)Translated by\s+(.+?)(?=\s+\|\s+|\s+ISBN:|\s+Publication Date:|\s+Paperback:|$)", metadata)
        contributors: list[dict[str, str]] = []
        if author:
            contributors.append({"name": author.group(1).strip(), "role": "author"})
        if translator:
            contributors.append({"name": translator.group(1).strip(), "role": "translator"})
        return contributors


def _response_text(response: Any, max_bytes: int | None = None) -> str:
    text = getattr(response, "text", "")
    value = text() if callable(text) else text
    result = value if isinstance(value, str) else str(value or "")
    if not result:
        body = getattr(response, "body", b"")
        if isinstance(body, bytes):
            result = body.decode("utf-8", errors="replace")
        elif isinstance(body, str):
            result = body
    if max_bytes is not None and len(result.encode("utf-8")) > max_bytes:
        raise ResponseTooLargeError(f"fetched response exceeded max_bytes={max_bytes}")
    return result


def _work(title: str) -> JsonDict:
    return {"title": title, "subtitle": None, "original_title": None, "original_language_code": None, "subjects": []}


def _edition(title: str, published_on: str | None, isbn_13: str | None) -> JsonDict:
    return {"title": title, "subtitle": None, "format": "paperback", "published_on": published_on, "isbn_13": isbn_13, "language_code": None, "page_count": None, "dimensions": None}


def _cover(cover_url: str | None, provider: str, source_uri: str) -> JsonDict:
    return {"source_url": cover_url, "provider": provider, "rights_basis": "local_cache_permitted", "attribution_text": f"Cover via {provider}", "attribution_url": source_uri, "cache_policy": "cache_allowed"}


def _displayed_fields(isbn_13: str | None, published_on: str | None, cover_url: str | None, description: str | None) -> list[str]:
    fields = ["title", "contributors", "publisher", "format", "storefront_url"]
    fields += [field for field, value in (("published_on", published_on), ("isbn_13", isbn_13), ("cover", cover_url), ("description", description)) if value]
    return fields


def _curation() -> JsonDict:
    return {"status": "approved", "notes": "Deterministic stealthy scrape from official Deep Vellum public catalog with field provenance."}


def _missing_fields(isbn_13: str | None, published_on: str | None) -> JsonDict:
    return {field: reason for field, value, reason in (("isbn_13", isbn_13, "not present in source record"), ("published_on", published_on, "not present in source record")) if not value}


def _field_sources(provider: str, source_uri: str, fields: list[str]) -> JsonDict:
    basis = "Operator-authorized public catalog refresh from official publisher pages/APIs; factual bibliographic metadata, official product descriptions, official cover URLs, purchase links, and source provenance preserved for each field."
    return {field: {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis} for field in ["subjects", *fields]}


def _positive_int(value: Any, *, default: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


def _optional_positive_int(value: Any) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _non_negative_float(value: Any, *, default: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    return parsed if parsed >= 0 else default
