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


def _isbn_from_meta(meta: list[dict]) -> str | None:
    for m in meta:
        key = m.get("key", "").lower()
        if "isbn" in key:
            val = m.get("value", "")
            if val and isinstance(val, str):
                cleaned = val.replace("-", "").strip()
                if len(cleaned) == 13 and cleaned.isdigit():
                    return cleaned
    return None


def _format_from_tags(tags: list[dict]) -> str:
    for tag in tags:
        name = tag.get("name", "").lower() if isinstance(tag, dict) else str(tag).lower()
        if "ebook" in name or "e-book" in name or "digital" in name:
            return "ebook"
        if "hardcover" in name or "hardback" in name or "cloth" in name:
            return "hardcover"
        if "paperback" in name or "softcover" in name or "trade" in name:
            return "paperback"
    return "paperback"


def _post_to_record(post: dict, provider: str, endpoint: str) -> dict[str, Any]:
    link = post.get("link", "")
    source_uri = link if link else f"{endpoint}/?p={post.get('id', '')}"
    title = post.get("title", {}).get("rendered", "") if isinstance(post.get("title"), dict) else str(post.get("title", ""))
    content = post.get("content", {}).get("rendered", "") if isinstance(post.get("content"), dict) else str(post.get("content", ""))
    excerpt = post.get("excerpt", {}).get("rendered", "") if isinstance(post.get("excerpt"), dict) else str(post.get("excerpt", ""))
    description = excerpt or content
    published_on = post.get("date", "")[:10] if post.get("date") else None
    isbn = _isbn_from_meta(post.get("meta", []))
    fmt = _format_from_tags(post.get("tags", []))

    featured_media = post.get("featured_media", 0)
    cover_url = ""
    if featured_media:
        cover_url = f"{endpoint}/wp-json/wp/v2/media/{featured_media}"

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": str(post.get("id", "")),
        "source_sku": isbn or "",
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
            "attribution_text": "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        },
        "description": description,
    }

    if not isbn:
        record["missing_fields"] = {"isbn_13": "not present in source record"}
        record["displayed_fields"] = [f for f in record["displayed_fields"] if f != "isbn_13"]

    tags = post.get("tags", [])
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
            url = f"{endpoint}/wp-json/wp/v2/posts?per_page=100&page={page}"
            response = await client.get(url)
            response.raise_for_status()

            if len(response.content) > max_bytes:
                break

            posts = response.json()
            if not posts:
                break

            for post in posts:
                records.append(_post_to_record(post, provider, endpoint))

            total_pages_str = response.headers.get("X-WP-TotalPages", "1")
            try:
                total_pages = int(total_pages_str)
            except ValueError:
                total_pages = 1

            if page >= total_pages:
                break

            page += 1
            if min_delay_ms:
                await asyncio.sleep(min_delay_ms / 1000)

    return records
