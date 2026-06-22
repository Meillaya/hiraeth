"""Manual async StealthyFetcher scraper for Deep Vellum's rendered catalog."""

from __future__ import annotations

import asyncio
import logging
import re
from dataclasses import dataclass
from html import unescape
from typing import Any, ClassVar
from urllib.parse import urljoin, urlparse

logger = logging.getLogger(__name__)
JsonDict = dict[str, Any]


@dataclass(frozen=True, slots=True)
class ProductCard:
    title: str
    vendor: str
    handle: str
    cover_url: str | None


@dataclass(frozen=True, slots=True)
class DetailPage:
    title: str | None
    description: str | None
    cover_url: str | None


class StealthyFetcher:
    """Lazy proxy for Scrapling's StealthyFetcher."""

    @staticmethod
    async def fetch_async(url: str, **kwargs: Any) -> Any:
        from scrapling.fetchers import StealthyFetcher as ScraplingStealthyFetcher

        fetch = getattr(ScraplingStealthyFetcher, "fetch_async", None)
        if fetch is None:
            fetch = ScraplingStealthyFetcher.async_fetch
        return await fetch(url, **kwargs)


class DeepVellumStealthySpider:
    """Scrape Deep Vellum product records with manual async StealthyFetcher calls."""

    allowed_vendors: ClassVar[set[str]] = {"Deep Vellum", "Deep Vellum Publishing"}
    base_url: ClassVar[str] = "https://store.deepvellum.org"
    default_catalog_url: ClassVar[str] = f"{base_url}/collections/all"
    default_provider: ClassVar[str] = "deep_vellum_official_store"
    fetch_options: ClassVar[JsonDict] = {
        "headless": True,
        "google_search": False,
        "network_idle": True,
        "wait_selector": ".sparq-result-inner",
        "useragent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36",
    }

    async def scrape_catalog(self, config: dict[str, Any]) -> list[JsonDict]:
        """Fetch the catalog, follow allowed product details, and return records."""
        provider = str(config.get("provider") or self.default_provider)
        catalog = await StealthyFetcher.fetch_async(
            self._catalog_url(config), **self.fetch_options
        )
        products = self._parse_catalog(_response_text(catalog))
        allowed = [product for product in products if self.is_allowed_vendor(product.vendor)]
        if not products or not allowed:
            logger.warning("Deep Vellum catalog produced no allowed products")
            return []

        semaphore = asyncio.Semaphore(4)
        records = await asyncio.gather(
            *(self._scrape_product(product, provider, semaphore) for product in allowed)
        )
        parsed = [record for record in records if record is not None]
        if not parsed:
            logger.warning("Deep Vellum detail pages produced no contributors")
        return parsed

    async def _scrape_product(
        self,
        product: ProductCard,
        provider: str,
        semaphore: asyncio.Semaphore,
    ) -> JsonDict | None:
        detail_url = self._detail_url(product.handle)
        async with semaphore:
            response = await StealthyFetcher.fetch_async(detail_url, **self.fetch_options)
        detail = self._parse_detail(_response_text(response))
        contributors = self._extract_contributors(detail.description)
        if not contributors:
            logger.warning("Skipping %s because no contributors were parsed", detail_url)
            return None
        return self._record(product, detail, contributors, provider, detail_url)

    def _record(
        self,
        product: ProductCard,
        detail: DetailPage,
        contributors: list[dict[str, str]],
        provider: str,
        detail_url: str,
    ) -> JsonDict:
        title = detail.title or product.title
        description = detail.description
        cover_url = detail.cover_url or product.cover_url
        record: JsonDict = {
            "provider": provider,
            "source_uri": detail_url,
            "source_product_id": product.handle,
            "publisher": self.normalize_vendor(product.vendor),
            "imprint": None,
            "work": _work(title),
            "edition": _edition(
                title,
                self._extract_publication_date(description),
                self._extract_isbn(description),
            ),
            "contributors": contributors,
            "cover": _cover(cover_url, provider),
            "field_sources": _field_sources(provider, detail_url),
        }
        if description:
            record["description"] = description
        if cover_url is None:
            record["cover"]["no_cover_reason"] = "detail_page_missing_cover"
        return record

    @classmethod
    def _catalog_url(cls, config: dict[str, Any]) -> str:
        configured = config.get("catalog_url")
        if isinstance(configured, str) and configured:
            return configured
        start_urls = config.get("start_urls")
        if isinstance(start_urls, list) and start_urls and isinstance(start_urls[0], str):
            return start_urls[0]
        return cls.default_catalog_url

    @classmethod
    def _detail_url(cls, handle: str) -> str:
        return f"{cls.base_url}/products/{handle}"

    @classmethod
    def _parse_catalog(cls, html: str) -> list[ProductCard]:
        starts = [match.start() for match in re.finditer(r"class=['\"][^'\"]*sparq-result-inner", html)]
        products: list[ProductCard] = []
        for index, start in enumerate(starts):
            end = starts[index + 1] if index + 1 < len(starts) else len(html)
            segment = html[start:end]
            product = _product_from_segment(segment, cls.base_url)
            if product:
                products.append(product)
        return products

    @classmethod
    def _parse_detail(cls, html: str) -> DetailPage:
        cleaned = _strip_unsafe_text(html)
        return DetailPage(
            title=_text_for_class(cleaned, "product-single__title"),
            description=_description_text(cleaned),
            cover_url=_first_image_url(cleaned, cls.base_url),
        )

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
        if not text:
            return None
        match = re.search(r"\b(?:ISBN|Paperback):\s*(97[89]\d{10})\b", text)
        return match.group(1) if match else None

    @staticmethod
    def _extract_publication_date(text: str | None) -> str | None:
        if not text:
            return None
        match = re.search(r"Publication Date:\s*([A-Z][a-z]+\s+\d{1,2},\s+\d{4}|\d{4}-\d{2}-\d{2})", text)
        return match.group(1).strip() if match else None

    @staticmethod
    def _extract_contributors(text: str | None) -> list[dict[str, str]]:
        if not text:
            return []
        contributors: list[dict[str, str]] = []
        author = re.search(
            r"\bBy\s+(.+?)(?=\s+Translated by\s+|\s+ISBN:|\s+Publication Date:|\s+Paperback:|$)",
            text,
        )
        translator = re.search(
            r"\bTranslated by\s+(.+?)(?=\s+ISBN:|\s+Publication Date:|\s+Paperback:|$)",
            text,
        )
        if author:
            contributors.append({"name": author.group(1).strip(), "role": "author"})
        if translator:
            contributors.append({"name": translator.group(1).strip(), "role": "translator"})
        return contributors


def _response_text(response: Any) -> str:
    text = getattr(response, "text", "")
    if callable(text):
        text = text()
    return text if isinstance(text, str) else str(text or "")


def _product_from_segment(segment: str, base_url: str) -> ProductCard | None:
    title = _text_for_class(segment, "sparq-item-title") or _text_for_class(segment, "product-title")
    vendor = _text_for_class(segment, "vendor-title") or _text_for_class(segment, "vendor")
    handle = _attr(segment, "data-handle") or _handle_from_href(_attr(segment, "href"))
    if not title or not vendor or not handle:
        return None
    return ProductCard(title, vendor, handle, _first_image_url(segment, base_url))


def _text_for_class(html: str, class_name: str) -> str | None:
    pattern = rf"<[^>]*class=['\"][^'\"]*{re.escape(class_name)}[^'\"]*['\"][^>]*>(.*?)</[^>]+>"
    match = re.search(pattern, html, re.DOTALL)
    return _clean_text(_strip_tags(match.group(1))) if match else None


def _description_text(html: str) -> str | None:
    match = re.search(
        r"<[^>]*class=['\"][^'\"]*product-single__description[^'\"]*rte[^'\"]*['\"][^>]*>(.*?)</div>",
        html,
        re.DOTALL,
    )
    return _clean_text(_strip_tags(match.group(1))) if match else None


def _first_image_url(html: str, base_url: str) -> str | None:
    match = re.search(r"<img\b(?P<attrs>[^>]*)>", html, re.DOTALL)
    if not match:
        return None
    src = _attr(match.group("attrs"), "src") or ""
    data_src = _attr(match.group("attrs"), "data-src") or ""
    candidate = data_src if data_src and "loader" in src else data_src or src
    return urljoin(base_url, candidate.strip()) if candidate else None


def _attr(html: str, name: str) -> str | None:
    match = re.search(rf"\b{re.escape(name)}=['\"]([^'\"]+)['\"]", html)
    return unescape(match.group(1)).strip() if match else None


def _handle_from_href(href: str | None) -> str | None:
    if not href:
        return None
    match = re.search(r"/products/([^/?#]+)", urlparse(href).path)
    return match.group(1) if match else None


def _strip_unsafe_text(html: str) -> str:
    return re.sub(r"<(script|style)\b.*?</\1>", " ", html, flags=re.DOTALL | re.IGNORECASE)


def _strip_tags(html: str) -> str:
    return unescape(re.sub(r"<[^>]+>", " ", html))


def _clean_text(text: str | None) -> str | None:
    if not text:
        return None
    cleaned = re.sub(r"\s+", " ", text).strip()
    return cleaned or None


def _work(title: str) -> JsonDict:
    return {"title": title, "subtitle": None, "original_title": None, "original_language_code": None, "subjects": []}


def _edition(title: str, published_on: str | None, isbn_13: str | None) -> JsonDict:
    return {
        "title": title, "subtitle": None, "format": "Paperback", "published_on": published_on,
        "isbn_13": isbn_13, "language_code": None, "page_count": None, "dimensions": None,
    }


def _cover(cover_url: str | None, provider: str) -> JsonDict:
    return {"source_url": cover_url, "rights_basis": "local_cache_permitted", "attribution_text": f"Cover via {provider}"}


def _field_sources(provider: str, source_uri: str) -> JsonDict:
    fields = ("title", "publisher", "cover", "isbn_13", "published_on", "description", "contributors")
    return {field: {"provider": provider, "source_uri": source_uri} for field in fields}
