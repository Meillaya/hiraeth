import asyncio
import re
from typing import Any

import httpx

from app.adapters.squarespace_images import absolute_url, listing_cover_urls, usable_cover_url

_EXCLUDED_CATEGORIES = {"bundles", "gift cards", "gift card", "merch", "sideline"}
_EXCLUDED_KEYWORDS = ("bundle", "subscription", "subscriber", "gift card")
_HEADERS = {"user-agent": "Mozilla/5.0 HiraethSidecar/1.0"}
_EBOOK_TITLE_SUFFIX = re.compile(r"\s*\((?:e-?book)\)\s*$", re.IGNORECASE)


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


def _first_isbn_from_variants(item: dict[str, Any]) -> str:
    structured_content = item.get("structuredContent", {})
    variants = structured_content.get("variants", []) if isinstance(structured_content, dict) else []
    for variant in variants:
        if not isinstance(variant, dict):
            continue
        sku = str(variant.get("sku") or "").replace("-", "").strip()
        if len(sku) == 13 and sku.isdigit():
            return sku
    return ""


def _is_book_item(item: dict[str, Any]) -> bool:
    categories = [str(category).strip().lower() for category in item.get("categories") or []]
    if any(category in _EXCLUDED_CATEGORIES for category in categories):
        return False

    haystack = " ".join(
        [
            str(item.get("title") or "").lower(),
            str(item.get("urlId") or "").lower(),
            " ".join(categories),
        ]
    )
    if any(keyword in haystack for keyword in _EXCLUDED_KEYWORDS):
        return False

    return True


def _cover_url(item: dict[str, Any], listing_cover_urls: dict[str, str] | None = None) -> str:
    item_id = str(item.get("id") or "")
    if listing_cover_urls and item_id in listing_cover_urls:
        return listing_cover_urls[item_id]

    assets = item.get("assets", [])
    for asset in assets or []:
        if isinstance(asset, dict) and asset.get("mediaType", "").startswith("image"):
            cover = asset.get("absoluteUrl", "") or asset.get("assetUrl", "")
            if usable_cover_url(cover):
                return str(cover)

    asset_url = item.get("assetUrl")
    if usable_cover_url(asset_url):
        return str(asset_url)

    structured_content = item.get("structuredContent", {})
    main_image = structured_content.get("mainImage", {}) if isinstance(structured_content, dict) else {}
    if isinstance(main_image, dict):
        cover = main_image.get("absoluteUrl", "") or main_image.get("assetUrl", "")
        if usable_cover_url(cover):
            return str(cover)

    return ""


def _author_from_excerpt(excerpt: str) -> str:
    match = re.search(r"<h[1-6][^>]*>(.*?)</h[1-6]>", excerpt, flags=re.IGNORECASE | re.DOTALL)
    if not match:
        return ""
    text = re.sub(r"<[^>]+>", " ", match.group(1))
    return re.sub(r"\s+", " ", text).strip()


def _strip_html(raw_html: str | None) -> str | None:
    if not raw_html:
        return None
    text = re.sub(r"<[^>]+>", " ", raw_html)
    text = re.sub(r"\s+", " ", text).strip()
    return text if text else None


def _canonical_title(title: str) -> str:
    return _EBOOK_TITLE_SUFFIX.sub("", title).strip()


def _format_from_item(item: dict[str, Any], custom_format: Any) -> str:
    if custom_format:
        return str(custom_format).strip().lower()

    categories = {str(category).strip().lower() for category in item.get("categories") or []}
    if "digital" in categories:
        return "ebook"
    if "print" in categories:
        return "paperback"

    structured_content = item.get("structuredContent", {})
    if isinstance(structured_content, dict) and structured_content.get("productType") == 2:
        return "ebook"

    return "paperback"


def _item_to_record(
    item: dict[str, Any],
    provider: str,
    endpoint: str,
    publisher_name: str | None = None,
    listing_cover_urls: dict[str, str] | None = None,
) -> dict[str, Any]:
    full_url = item.get("fullUrl", "")
    source_uri = absolute_url(endpoint, full_url) if full_url else f"{endpoint}/{item.get('id', '')}"
    title = _canonical_title(str(item.get("title", "")))
    body = item.get("body", "") or item.get("excerpt", "")
    description = _strip_html(body)
    custom_content = item.get("customContent", {})
    custom_isbn = custom_content.get("isbn", "") if isinstance(custom_content, dict) else ""
    isbn = str(custom_isbn).replace("-", "").strip() or _first_isbn_from_variants(item)
    author = custom_content.get("author", "") if isinstance(custom_content, dict) else ""
    if not author and isinstance(body, str):
        author = _author_from_excerpt(body)
    custom_format = custom_content.get("format", "") if isinstance(custom_content, dict) else ""
    fmt = _format_from_item(item, custom_format)
    published_on = custom_content.get("publishedOn", "") if isinstance(custom_content, dict) else ""
    if published_on and isinstance(published_on, str):
        published_on = published_on[:10]

    cover_url = _cover_url(item, listing_cover_urls)

    contributors = []
    if author:
        contributors.append({"name": author, "role": "author"})

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": str(item.get("id", "")),
        "source_sku": isbn,
        "publisher": publisher_name or provider,
        "imprint": None,
        "work": {
            "title": title,
            "subtitle": None,
            "original_title": None,
            "publication_state": "published",
        },
        "edition": {
            "title": title,
            "subtitle": None,
            "format": fmt,
            "published_on": published_on or None,
            "isbn_13": isbn if isbn and len(isbn.replace("-", "")) == 13 else None,
        },
        "contributors": contributors,
        "displayed_fields": _displayed_fields(published_on, isbn, cover_url, description),
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
            "attribution_text": "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        },
        "description": description,
    }

    if not cover_url:
        record["no_cover_reason"] = "no usable cover image URL present in source record"

    if not record["edition"]["isbn_13"]:
        record["missing_fields"] = {"isbn_13": "not present in source record"}
        record["displayed_fields"] = [f for f in record["displayed_fields"] if f != "isbn_13"]

    tags = item.get("tags", [])
    if tags:
        record["work"]["subjects"] = [str(t) for t in tags]
        if "subjects" not in record["displayed_fields"]:
            record["displayed_fields"].append("subjects")

    return record


def _displayed_fields(
    published_on: str | None,
    isbn: str | None,
    cover_url: str | None,
    description: str | None,
) -> list[str]:
    fields = ["title", "contributors", "publisher", "format", "storefront_url"]
    fields += [
        field
        for field, value in (
            ("published_on", published_on),
            ("isbn_13", isbn),
            ("cover", cover_url),
            ("description", description),
        )
        if value
    ]
    return fields


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
    publisher_name = config.get("publisher_name")
    rate_limit = config.get("rate_limit", {})
    min_delay_ms = rate_limit.get("min_delay_ms", 0)
    max_bytes = rate_limit.get("max_bytes", 10 * 1024 * 1024)

    async with httpx.AsyncClient() as client:
        url = f"{endpoint}?format=json"
        response = await client.get(url, headers=_HEADERS)
        response.raise_for_status()

        if len(response.content) > max_bytes:
            return []

        data = response.json()

        listing_response = await client.get(endpoint, headers=_HEADERS)
        html_cover_urls = (
            listing_cover_urls(listing_response.text, endpoint)
            if listing_response.status_code < 400 and len(listing_response.content) <= max_bytes
            else {}
        )
        collection = data.get("collection", {})
        if isinstance(collection, dict) and collection.get("items"):
            items = collection["items"]
        else:
            items = data.get("items", [])

        records: list[dict[str, Any]] = []
        for item in items:
            if not _is_book_item(item):
                continue
            record = _item_to_record(item, provider, endpoint, publisher_name, html_cover_urls)
            if record["contributors"]:
                records.append(record)

        if min_delay_ms:
            await asyncio.sleep(min_delay_ms / 1000)

    return records
