import re
from typing import Any

import anyio
import httpx


def _strip_html(raw_html: str | None) -> str | None:
    if not raw_html:
        return None
    text = re.sub(r"<[^>]+>", " ", raw_html)
    text = re.sub(r"\s+", " ", text).strip()
    return text if text != "" else None


_EXCLUDED_PRODUCT_TYPES = {"bundles", "gift card", "gift cards", "sideline", "merch", "merchandise"}
_EXCLUDED_KEYWORDS = ("bundle", "subscriber", "subscription", "care package", "package")
_GENERIC_VENDORS = {"chpbeta", "open letter", "various"}
_HEADERS = {"user-agent": "Mozilla/5.0 HiraethSidecar/1.0"}


def _is_book_product(product: dict[str, Any]) -> bool:
    product_type = (product.get("product_type") or product.get("type") or "").strip()
    if product_type.lower() in _EXCLUDED_PRODUCT_TYPES:
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


def _isbn_from_text(text: str | None) -> str | None:
    match = re.search(r"97[89](?:[-\s]?\d){10}", text or "")
    if not match:
        return None
    isbn = match.group(0).replace("-", "").replace(" ", "")
    return isbn if _valid_isbn13(isbn) else None


def _valid_isbn13(isbn: str) -> bool:
    if len(isbn) != 13 or not isbn.isdigit():
        return False
    total = sum((1 if index % 2 == 0 else 3) * int(digit) for index, digit in enumerate(isbn[:12]))
    return (10 - (total % 10)) % 10 == int(isbn[-1])


def _contributors_from_product(product: dict[str, Any], description: str | None) -> list[dict[str, str]]:
    vendor = str(product.get("vendor") or "").strip()
    if vendor and vendor.lower() not in _GENERIC_VENDORS:
        return [{"name": vendor, "role": "author"}]

    if not description:
        return []

    match = re.match(
        r"^(?:[A-Z][A-Za-z/& -]+\s+)?(?P<role>by|edited by)\s+(?P<name>.+?)(?=\s+(?:January|February|March|April|May|June|July|August|September|October|November|December|\d{4}|•|$))",
        description,
        flags=re.IGNORECASE,
    )
    if not match:
        return []

    role = "editor" if match.group("role").lower() == "edited by" else "author"
    return [{"name": match.group("name").strip(), "role": role}]


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


def _displayed_fields(
    contributors: list[dict[str, str]],
    published_on: str | None,
    isbn: str | None,
    cover_url: str,
    description: str | None,
    tags: list[str],
) -> list[str]:
    optional_fields = (
        ("contributors", contributors),
        ("published_on", published_on),
        ("isbn_13", isbn),
        ("cover", cover_url),
        ("description", description),
        ("subjects", tags),
    )
    return ["title", "publisher", "format", "storefront_url"] + [field for field, value in optional_fields if value]


def _product_variant_to_record(
    product: dict[str, Any],
    variant: dict[str, Any],
    provider: str,
    endpoint: str,
    publisher_name: str | None = None,
) -> dict[str, Any]:
    handle = product.get("handle", "")
    source_uri = f"{endpoint}/products/{handle}"
    product_id = product.get("id", "")
    variant_id = variant.get("id", "")
    sku = variant.get("sku", "")
    vendor = product.get("vendor", "")
    title = product.get("title", "")
    published_at = product.get("published_at")
    published_on = published_at[:10] if published_at and isinstance(published_at, str) else None
    tags = product.get("tags", [])
    body_html = product.get("body_html", "")
    description = _strip_html(body_html)
    isbn = _isbn_from_sku(sku) or _isbn_from_text(description)
    images = product.get("images", [])
    cover_url = images[0].get("src", "") if images else ""
    variant_title = variant.get("title", "")
    fmt = _format_from_variant_title(variant_title) or "paperback"
    contributors = _contributors_from_product(product, description)

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": f"{product_id}-{variant_id}",
        "source_sku": isbn or sku,
        "publisher": publisher_name or vendor,
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
        "contributors": contributors,
        "displayed_fields": _displayed_fields(
            contributors,
            published_on,
            isbn,
            cover_url,
            description,
            tags,
        ),
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
        "description": description,
    }

    if not isbn:
        record["missing_fields"] = {"isbn_13": "not present in source record"}

    return record


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
    publisher_name = config.get("publisher_name")
    rate_limit = config.get("rate_limit", {})
    min_delay_ms = rate_limit.get("min_delay_ms", 0)
    max_bytes = rate_limit.get("max_bytes", 10 * 1024 * 1024)
    allowed_vendors = set(config["api"].get("allowed_vendors") or [])

    records: list[dict[str, Any]] = []
    seen_isbns = set()
    page = 1

    async with httpx.AsyncClient() as client:
        while True:
            url = f"{endpoint}/products.json?limit=250&page={page}"
            response = await client.get(url, headers=_HEADERS)
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
                seen_keys = set()
                if variants:
                    for variant in variants:
                        record = _product_variant_to_record(
                            product,
                            variant,
                            provider,
                            endpoint,
                            publisher_name,
                        )
                        key = (record["source_uri"], record["edition"].get("isbn_13") or record["source_sku"])
                        isbn = record["edition"].get("isbn_13")
                        if record["contributors"] and key not in seen_keys and (not isbn or isbn not in seen_isbns):
                            records.append(record)
                            seen_keys.add(key)
                            if isbn:
                                seen_isbns.add(isbn)
                else:
                    dummy_variant = {"id": product.get("id", ""), "sku": "", "title": ""}
                    record = _product_variant_to_record(
                        product,
                        dummy_variant,
                        provider,
                        endpoint,
                        publisher_name,
                    )
                    isbn = record["edition"].get("isbn_13")
                    if record["contributors"] and (not isbn or isbn not in seen_isbns):
                        records.append(record)
                        if isbn:
                            seen_isbns.add(isbn)

            if len(products) < 250:
                break

            page += 1
            if min_delay_ms:
                await anyio.sleep(min_delay_ms / 1000)

    return records
