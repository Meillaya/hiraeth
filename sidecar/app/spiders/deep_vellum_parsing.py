"""Parsing helpers for Deep Vellum catalog and detail HTML."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from html import unescape
from json import JSONDecodeError
from typing import Any, Final
from urllib.parse import urljoin, urlparse

JsonDict = dict[str, Any]

_EVENTS_RE: Final = re.compile(r'"events":"(?P<events>(?:\\.|[^"\\])*)"')
_SPARQ_CARD_RE: Final = re.compile(r"class=['\"][^'\"]*sparq-result-inner")
_BOOK_PRODUCT_TYPE: Final = "books"
_SHOPIFY_FILES_PREFIX: Final = "/s/files/1/0433/1651/0883/"


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


def parse_catalog(html: str, base_url: str) -> list[ProductCard]:
    """Extract products from current Shopify events, falling back to Sparq cards."""
    embedded_products = _products_from_shopify_events(html, base_url)
    if embedded_products:
        return embedded_products
    return _products_from_sparq_cards(html, base_url)


def parse_detail(html: str, base_url: str) -> DetailPage:
    """Extract detail enrichment fields from a Deep Vellum product page."""
    cleaned = _strip_unsafe_text(html)
    return DetailPage(
        title=_text_for_class(cleaned, "product-single__title"),
        description=_description_text(cleaned),
        cover_url=_first_image_url(cleaned, base_url),
    )


def _products_from_shopify_events(html: str, base_url: str) -> list[ProductCard]:
    products: list[ProductCard] = []
    seen_handles: set[str] = set()
    for match in _EVENTS_RE.finditer(html):
        products.extend(_products_from_event_payload(match.group("events"), base_url, seen_handles))
    return products


def _products_from_event_payload(payload: str, base_url: str, seen_handles: set[str]) -> list[ProductCard]:
    try:
        decoded_payload = json.loads(f'"{payload}"')
        events = json.loads(decoded_payload)
    except JSONDecodeError:
        return []

    products: list[ProductCard] = []
    if not isinstance(events, list):
        return products

    for event in events:
        variants = _variants_from_event(event)
        for variant in variants:
            product = _product_from_variant(variant, base_url, seen_handles)
            if product:
                products.append(product)
    return products


def _variants_from_event(event: Any) -> list[JsonDict]:
    if not isinstance(event, list) or len(event) != 2 or event[0] != "collection_viewed":
        return []
    payload = event[1]
    if not isinstance(payload, dict):
        return []
    collection = payload.get("collection")
    if not isinstance(collection, dict):
        return []
    variants = collection.get("productVariants")
    if not isinstance(variants, list):
        return []
    return [variant for variant in variants if isinstance(variant, dict)]


def _product_from_variant(variant: JsonDict, base_url: str, seen_handles: set[str]) -> ProductCard | None:
    product = variant.get("product")
    if not isinstance(product, dict):
        return None

    product_type = _clean_text(str(product.get("type") or ""))
    if product_type and product_type.lower() != _BOOK_PRODUCT_TYPE:
        return None

    title = _clean_text(str(product.get("title") or ""))
    vendor = _clean_text(str(product.get("vendor") or ""))
    handle = _handle_from_href(str(product.get("url") or ""))
    if not title or not vendor or not handle or handle in seen_handles:
        return None

    seen_handles.add(handle)
    return ProductCard(title=title, vendor=vendor, handle=handle, cover_url=_image_from_variant(variant, base_url))


def _image_from_variant(variant: JsonDict, base_url: str) -> str | None:
    image = variant.get("image")
    if not isinstance(image, dict):
        return None
    source = _clean_text(str(image.get("src") or ""))
    return _normalize_image_url(urljoin(base_url, source)) if source else None


def _products_from_sparq_cards(html: str, base_url: str) -> list[ProductCard]:
    starts = [match.start() for match in _SPARQ_CARD_RE.finditer(html)]
    products: list[ProductCard] = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(html)
        product = _product_from_segment(html[start:end], base_url)
        if product:
            products.append(product)
    return products


def _product_from_segment(segment: str, base_url: str) -> ProductCard | None:
    title = _text_for_class(segment, "sparq-item-title") or _text_for_class(segment, "product-title")
    vendor = _text_for_class(segment, "vendor-title") or _text_for_class(segment, "vendor")
    handle = _attr(segment, "data-handle") or _handle_from_href(_attr(segment, "href"))
    return ProductCard(title, vendor, handle, _first_image_url(segment, base_url)) if title and vendor and handle else None


def _text_for_class(html: str, class_name: str) -> str | None:
    match = re.search(rf"<[^>]*class=['\"][^'\"]*{re.escape(class_name)}[^'\"]*['\"][^>]*>(.*?)</[^>]+>", html, re.DOTALL)
    return _clean_text(_strip_tags(match.group(1))) if match else None


def _description_text(html: str) -> str | None:
    match = re.search(r"<[^>]*class=['\"][^'\"]*product-single__description[^'\"]*rte[^'\"]*['\"][^>]*>(.*?)</div>", html, re.DOTALL)
    return _clean_text(_strip_tags(match.group(1))) if match else None


def _first_image_url(html: str, base_url: str) -> str | None:
    match = re.search(r"<img\b(?P<attrs>[^>]*)>", html, re.DOTALL)
    if not match:
        return None
    src = _attr(match.group("attrs"), "src") or ""
    data_src = _attr(match.group("attrs"), "data-src") or ""
    candidate = data_src if data_src and "loader" in src else data_src or src
    return _normalize_image_url(urljoin(base_url, candidate.strip())) if candidate else None


def _normalize_image_url(url: str) -> str:
    parsed = urlparse(url)
    if parsed.netloc == "store.deepvellum.org" and parsed.path.startswith("/cdn/shop/"):
        path = parsed.path.removeprefix("/cdn/shop/")
        return parsed._replace(netloc="cdn.shopify.com", path=f"{_SHOPIFY_FILES_PREFIX}{path}").geturl()
    return url


def _attr(html: str, name: str) -> str | None:
    match = re.search(rf"\b{re.escape(name)}=['\"]([^'\"]+)['\"]", html)
    return unescape(match.group(1)).strip() if match else None


def _handle_from_href(href: str | None) -> str | None:
    match = re.search(r"/products/([^/?#]+)", urlparse(href or "").path)
    return match.group(1) if match else None


def _strip_unsafe_text(html: str) -> str:
    return re.sub(r"<(script|style)\b.*?</\1>", " ", html, flags=re.DOTALL | re.IGNORECASE)


def _strip_tags(html: str) -> str:
    separated = re.sub(r"</?(?:p|div|h[1-6])\b[^>]*>|<br\s*/?>", " | ", html, flags=re.IGNORECASE)
    return unescape(re.sub(r"<[^>]+>", " ", separated))


def _clean_text(text: str | None) -> str | None:
    cleaned = re.sub(r"\s+", " ", text or "").strip()
    return cleaned or None
