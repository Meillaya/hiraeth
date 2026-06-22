import asyncio
from typing import Any

import httpx


def _isbn_from_sku(sku: str | None) -> str | None:
    if sku and len(sku) == 13 and sku.isdigit():
        return sku
    if sku and len(sku) == 17 and sku.replace("-", "").isdigit():
        return sku.replace("-", "")
    return None


def _format_from_product(product: dict) -> str:
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


def _published_on_from_product(product: dict) -> str | None:
    meta_data = product.get("meta_data", [])
    for meta in meta_data:
        if meta.get("key", "").lower() in ("publication_date", "published_on", "pub_date"):
            val = meta.get("value", "")
            if val and isinstance(val, str):
                return val[:10]
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


def _product_to_record(product: dict, provider: str, endpoint: str) -> dict[str, Any]:
    permalink = product.get("permalink", "")
    source_uri = permalink if permalink else f"{endpoint}/product/{product.get('id', '')}"
    product_id = product.get("id", "")
    sku = product.get("sku", "")
    isbn = _isbn_from_sku(sku)
    title = product.get("name", "")
    published_on = _published_on_from_product(product) or product.get("date_created", "")[:10] or None
    images = product.get("images", [])
    cover_url = images[0].get("src", "") if images else ""
    description = product.get("short_description", "") or product.get("description", "")
    fmt = _format_from_product(product)
    publisher = product.get("vendor", "") or product.get("store", "") or provider

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": f"{product_id}-{sku}" if sku else str(product_id),
        "source_sku": sku,
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
            "attribution_text": f"Cover via {publisher} official source" if publisher else "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        },
        "description": description,
    }

    if not isbn:
        record["missing_fields"] = {"isbn_13": "not present in source record"}
        record["displayed_fields"] = [f for f in record["displayed_fields"] if f != "isbn_13"]

    tags = product.get("tags", [])
    if tags:
        record["work"]["subjects"] = [t.get("name", "") if isinstance(t, dict) else str(t) for t in tags]
        if "subjects" not in record["displayed_fields"]:
            record["displayed_fields"].append("subjects")

    return record


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
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
                records.append(_product_to_record(product, provider, endpoint))

            if len(products) < 100:
                break

            page += 1
            if min_delay_ms:
                await asyncio.sleep(min_delay_ms / 1000)

    return records
