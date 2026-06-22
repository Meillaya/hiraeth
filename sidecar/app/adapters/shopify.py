import asyncio
import re
from typing import Any

import httpx


def _strip_html(raw_html: str | None) -> str | None:
    if not raw_html:
        return None
    text = re.sub(r"<[^>]+>", " ", raw_html)
    text = re.sub(r"\s+", " ", text).strip()
    return text if text != "" else None


_EXCLUDED_PRODUCT_TYPES = {"Bundles", "Gift Card", "Gift Cards", "Sideline", "Merch"}
_EXCLUDED_KEYWORDS = ("bundle", "subscriber", "subscription", "care package", "package")


def _is_book_product(product: dict[str, Any]) -> bool:
    product_type = (product.get("product_type") or product.get("type") or "").strip()
    if product_type in _EXCLUDED_PRODUCT_TYPES:
        return False
    collections = [c.lower() for c in (product.get("collections") or [])]
    if collections and "books" not in collections:
        return False
    tags = [t.lower() for t in (product.get("tags") or [])]
    haystack = " ".join(
        [
            (product.get("handle") or "").lower(),
            (product.get("title") or "").lower(),
            product_type.lower(),
            " ".join(tags),
        ]
    )
    if any(keyword in haystack for keyword in _EXCLUDED_KEYWORDS):
        return False
    return True


def _isbn_from_sku(sku: str | None) -> str | None:
    if sku and len(sku) == 13 and sku.isdigit():
        return sku
    if sku and len(sku) == 17 and sku.replace("-", "").isdigit():
        return sku.replace("-", "")
    return None


def _format_from_variant_title(variant_title: str | None) -> str | None:
    if not variant_title:
        return None
    vt = variant_title.lower()
    if "ebook" in vt or "e-book" in vt or "digital" in vt:
        return "ebook"
    if "hardcover" in vt or "hardback" in vt or "cloth" in vt:
        return "hardcover"
    if "paperback" in vt or "softcover" in vt or "trade" in vt:
        return "paperback"
    return None


def _build_field_sources(provider: str, source_uri: str) -> dict[str, Any]:
    basis = "Operator-authorized public catalog refresh from official publisher pages/APIs; factual bibliographic metadata, official product descriptions, official cover URLs, purchase links, and source provenance preserved for each field."
    return {
        "title": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "contributors": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "publisher": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "format": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "published_on": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "isbn_13": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "cover": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "description": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "storefront_url": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
        "subjects": {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis},
    }


def _product_variant_to_record(product: dict, variant: dict, provider: str, endpoint: str) -> dict[str, Any]:
    handle = product.get("handle", "")
    source_uri = f"{endpoint}/products/{handle}"
    product_id = product.get("id", "")
    variant_id = variant.get("id", "")
    sku = variant.get("sku", "")
    isbn = _isbn_from_sku(sku)
    vendor = product.get("vendor", "")
    title = product.get("title", "")
    published_at = product.get("published_at")
    published_on = published_at[:10] if published_at and isinstance(published_at, str) else None
    tags = product.get("tags", [])
    body_html = product.get("body_html", "")
    images = product.get("images", [])
    cover_url = images[0].get("src", "") if images else ""
    variant_title = variant.get("title", "")
    fmt = _format_from_variant_title(variant_title) or "paperback"

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": f"{product_id}-{variant_id}",
        "source_sku": sku,
        "publisher": vendor,
        "imprint": None,
        "work": {
            "title": title,
            "subtitle": None,
            "original_title": None,
            "publication_state": "published",
            "subjects": tags,
        },
        "edition": {
            "title": title,
            "subtitle": None,
            "format": fmt,
            "published_on": published_on,
            "isbn_13": isbn,
        },
        "contributors": [],
        "displayed_fields": [
            "title",
            "contributors",
            "publisher",
            "format",
            "published_on",
            "isbn_13",
            "cover",
            "description",
            "storefront_url",
            "subjects",
        ],
        "curation": {
            "status": "approved",
            "notes": "Operator-authorized full-catalog refresh from public source; generated deterministically with field provenance.",
        },
        "storefront_url": source_uri,
        "field_sources": _build_field_sources(provider, source_uri),
        "cover": {
            "source_url": cover_url,
            "provider": provider,
            "rights_basis": "local_cache_permitted",
            "attribution_text": f"Cover via {vendor} official source" if vendor else "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        },
        "description": _strip_html(body_html),
    }

    if not isbn:
        record["missing_fields"] = {"isbn_13": "not present in source record"}
        record["displayed_fields"] = [f for f in record["displayed_fields"] if f != "isbn_13"]

    return record


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
    rate_limit = config.get("rate_limit", {})
    min_delay_ms = rate_limit.get("min_delay_ms", 0)
    max_bytes = rate_limit.get("max_bytes", 10 * 1024 * 1024)
    allowed_vendors = set(config["api"].get("allowed_vendors") or [])

    records: list[dict[str, Any]] = []
    page = 1

    async with httpx.AsyncClient() as client:
        while True:
            url = f"{endpoint}/products.json?limit=250&page={page}"
            response = await client.get(url)
            response.raise_for_status()

            if len(response.content) > max_bytes:
                break

            data = response.json()
            products = data.get("products", [])
            if not products:
                break

            for product in products:
                vendor = product.get("vendor") or ""
                if allowed_vendors and vendor not in allowed_vendors:
                    continue
                if not _is_book_product(product):
                    continue
                variants = product.get("variants", [])
                if variants:
                    for variant in variants:
                        records.append(_product_variant_to_record(product, variant, provider, endpoint))
                else:
                    dummy_variant = {"id": product.get("id", ""), "sku": "", "title": ""}
                    records.append(_product_variant_to_record(product, dummy_variant, provider, endpoint))

            if len(products) < 250:
                break

            page += 1
            if min_delay_ms:
                await asyncio.sleep(min_delay_ms / 1000)

    return records
