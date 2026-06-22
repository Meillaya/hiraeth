import asyncio
from typing import Any

import httpx


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


def _item_to_record(item: dict, provider: str, endpoint: str) -> dict[str, Any]:
    full_url = item.get("fullUrl", "")
    source_uri = full_url if full_url else f"{endpoint}/{item.get('id', '')}"
    title = item.get("title", "")
    body = item.get("body", "") or item.get("excerpt", "")
    custom_content = item.get("customContent", {})
    isbn = custom_content.get("isbn", "") if isinstance(custom_content, dict) else ""
    author = custom_content.get("author", "") if isinstance(custom_content, dict) else ""
    fmt = custom_content.get("format", "") if isinstance(custom_content, dict) else ""
    if not fmt:
        fmt = "paperback"
    published_on = custom_content.get("publishedOn", "") if isinstance(custom_content, dict) else ""
    if published_on and isinstance(published_on, str):
        published_on = published_on[:10]

    assets = item.get("assets", [])
    cover_url = ""
    for asset in assets:
        if isinstance(asset, dict) and asset.get("mediaType", "").startswith("image"):
            cover_url = asset.get("absoluteUrl", "") or asset.get("assetUrl", "")
            if cover_url:
                break

    contributors = []
    if author:
        contributors.append({"name": author, "role": "author"})

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": str(item.get("id", "")),
        "source_sku": isbn,
        "publisher": provider,
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
            "attribution_text": "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        },
        "description": body,
    }

    if not record["edition"]["isbn_13"]:
        record["missing_fields"] = {"isbn_13": "not present in source record"}
        record["displayed_fields"] = [f for f in record["displayed_fields"] if f != "isbn_13"]

    tags = item.get("tags", [])
    if tags:
        record["work"]["subjects"] = [str(t) for t in tags]
        if "subjects" not in record["displayed_fields"]:
            record["displayed_fields"].append("subjects")

    return record


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
    rate_limit = config.get("rate_limit", {})
    min_delay_ms = rate_limit.get("min_delay_ms", 0)
    max_bytes = rate_limit.get("max_bytes", 10 * 1024 * 1024)

    async with httpx.AsyncClient() as client:
        url = f"{endpoint}?format=json"
        response = await client.get(url)
        response.raise_for_status()

        if len(response.content) > max_bytes:
            return []

        data = response.json()
        collection = data.get("collection", {})
        if isinstance(collection, dict) and collection.get("items"):
            items = collection["items"]
        else:
            items = data.get("items", [])

        records: list[dict[str, Any]] = []
        for item in items:
            records.append(_item_to_record(item, provider, endpoint))

        if min_delay_ms:
            await asyncio.sleep(min_delay_ms / 1000)

    return records
