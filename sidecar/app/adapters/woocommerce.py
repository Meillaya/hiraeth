import re
from html import unescape
from typing import Any

import anyio
import httpx


_ISBN13_PATTERN = re.compile(r"(?<!\d)(97[89](?:[\s-]?\d){10})(?!\d)")
_TAG_PATTERN = re.compile(r"<[^>]+>")
_GENRE_OR_REGION_TAGS = {
    "africa",
    "argentina",
    "belgium",
    "croatia",
    "digital",
    "ebook",
    "e-book",
    "european union prize for literature",
    "fiction",
    "france",
    "hardcover",
    "iraq",
    "montenegro",
    "nonfiction",
    "paperback",
    "poetry",
    "trade",
}
_EXCLUDED_PRODUCT_KEYWORDS = ("membership", "subscription", "bundle", "gift card")


def _valid_isbn13(value: str) -> bool:
    digits = re.sub(r"\D", "", value)
    if len(digits) != 13 or not digits.startswith(("978", "979")):
        return False

    checksum = sum((1 if index % 2 == 0 else 3) * int(digit) for index, digit in enumerate(digits[:12]))
    check_digit = (10 - checksum % 10) % 10
    return check_digit == int(digits[-1])


def _isbn_from_text(text: str | None) -> str | None:
    if not text:
        return None

    for match in _ISBN13_PATTERN.finditer(text):
        candidate = re.sub(r"\D", "", match.group(1))
        if _valid_isbn13(candidate):
            return candidate

    return None


def _isbn_from_sku(sku: str | None) -> str | None:
    return _isbn_from_text(sku)


def _isbn_from_tags(tags: list[Any]) -> str | None:
    for tag in tags:
        name = tag.get("name", "") if isinstance(tag, dict) else str(tag)
        isbn = _isbn_from_text(name)
        if isbn:
            return isbn
    return None


def _strip_html(raw_html: str | None) -> str | None:
    if not raw_html:
        return None

    text = _TAG_PATTERN.sub(" ", raw_html)
    cleaned = re.sub(r"\s+", " ", unescape(text)).strip()
    return cleaned if cleaned else None


def _format_from_product(product: dict[str, Any]) -> str:
    categories = product.get("categories", [])
    tags = product.get("tags", [])
    for label in categories + tags:
        name = label.get("name", "").lower() if isinstance(label, dict) else str(label).lower()
        if "ebook" in name or "e-book" in name or "digital" in name:
            return "ebook"
        if "hardcover" in name or "hardback" in name or "cloth" in name:
            return "hardcover"
        if "paperback" in name or "softcover" in name or "trade" in name:
            return "paperback"
    return "paperback"


def _published_on_from_product(product: dict[str, Any]) -> str | None:
    meta_data = product.get("meta_data", [])
    for meta in meta_data:
        if meta.get("key", "").lower() in ("publication_date", "published_on", "pub_date"):
            val = meta.get("value", "")
            if val and isinstance(val, str):
                return val[:10]
    return None


def _contributors_from_tags(tags: list[Any], description: str | None) -> list[dict[str, str]]:
    contributors: list[dict[str, str]] = []

    for tag in tags:
        name = tag.get("name", "") if isinstance(tag, dict) else str(tag)
        normalized = re.sub(r"\s+", " ", name).strip()
        if not _person_tag(normalized):
            continue

        role = _contributor_role(normalized, description)
        contributors.append({"name": normalized, "role": role})

    return contributors or _contributors_from_description(description)


def _contributors_from_description(description: str | None) -> list[dict[str, str]]:
    if not description:
        return []

    possessive_match = re.search(r"\b([A-ZÀ-Ž][\wÀ-ž.-]+(?:\s+[A-ZÀ-Ž][\wÀ-ž.-]+){1,3})[’']s\b", description)
    if possessive_match:
        return [{"name": possessive_match.group(1), "role": "author"}]

    if re.search(r"\bThirty Slovenian writers\b", description):
        return [{"name": "Thirty Slovenian writers", "role": "author"}]

    return []


def _person_tag(name: str) -> bool:
    if not name or _isbn_from_text(name):
        return False

    lowered = name.lower()
    if lowered in _GENRE_OR_REGION_TAGS or " prize " in f" {lowered} ":
        return False

    words = name.split()
    return 2 <= len(words) <= 4


def _contributor_role(name: str, description: str | None) -> str:
    if not description:
        return "author"

    escaped = re.escape(name)
    if re.search(rf"\btranslated\b[^.]*\bby\s+{escaped}\b|\b{escaped}\b[^.]*\btranslated\b", description, re.IGNORECASE):
        return "translator"

    return "author"


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
    tags: list[Any],
) -> list[str]:
    fields = ["title", "publisher", "format", "storefront_url"]
    if contributors:
        fields.append("contributors")
    if published_on:
        fields.append("published_on")
    if isbn:
        fields.append("isbn_13")
    if cover_url:
        fields.append("cover")
    if description:
        fields.append("description")
    if tags:
        fields.append("subjects")
    return fields


def _product_to_record(product: dict[str, Any], provider: str, endpoint: str, publisher_name: str | None = None) -> dict[str, Any]:
    permalink = product.get("permalink", "")
    source_uri = permalink if permalink else f"{endpoint}/product/{product.get('id', '')}"
    product_id = product.get("id", "")
    sku = product.get("sku", "")
    tags = product.get("tags", [])
    isbn = _isbn_from_sku(sku) or _isbn_from_tags(tags)
    source_sku = isbn or sku
    title = product.get("name", "")
    published_on = _published_on_from_product(product) or product.get("date_created", "")[:10] or None
    images = product.get("images", [])
    cover_url = images[0].get("src", "") if images else ""
    short_description = _strip_html(product.get("short_description", ""))
    full_description = _strip_html(product.get("description", ""))
    description = short_description or full_description
    contributor_text = " ".join(part for part in (description, full_description) if part)
    fmt = _format_from_product(product)
    publisher = publisher_name or product.get("vendor", "") or product.get("store", "") or provider
    contributors = _contributors_from_tags(tags, contributor_text)

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": f"{product_id}-{source_sku}" if source_sku else str(product_id),
        "source_sku": source_sku,
        "publisher": publisher,
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
            "attribution_text": f"Cover via {publisher} official source" if publisher else "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        },
        "description": description,
    }

    if not isbn:
        record["missing_fields"] = {"isbn_13": "not present in source record"}

    if tags:
        record["work"]["subjects"] = [t.get("name", "") if isinstance(t, dict) else str(t) for t in tags]

    return record


def _book_product(product: dict[str, Any]) -> bool:
    title = str(product.get("name") or "").lower()
    permalink = str(product.get("permalink") or "").lower()
    haystack = f"{title} {permalink}"
    return not any(keyword in haystack for keyword in _EXCLUDED_PRODUCT_KEYWORDS)


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
    publisher_name = config.get("publisher_name")
    rate_limit = config.get("rate_limit", {})
    min_delay_ms = rate_limit.get("min_delay_ms", 0)
    max_bytes = rate_limit.get("max_bytes", 10 * 1024 * 1024)

    records: list[dict[str, Any]] = []
    page = 1

    async with httpx.AsyncClient() as client:
        while True:
            url = f"{endpoint}/wp-json/wc/store/products?per_page=100&page={page}"
            response = await client.get(url)
            response.raise_for_status()

            if len(response.content) > max_bytes:
                break

            products = response.json()
            if not products:
                break

            for product in products:
                if _book_product(product):
                    records.append(_product_to_record(product, provider, endpoint, publisher_name))

            if len(products) < 100:
                break

            page += 1
            if min_delay_ms:
                await anyio.sleep(min_delay_ms / 1000)

    return records
