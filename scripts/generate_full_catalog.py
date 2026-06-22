#!/usr/bin/env python3
"""Refresh full-catalog fixtures from authorized public publisher sources.

This operator-run tool intentionally uses live public endpoints/pages. Normal tests
consume the checked-in JSON fixtures that this script writes.
"""
from __future__ import annotations

import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from generate_full_catalog_deep_vellum import (
    DEEP_VELLUM_PROVIDER,
    build_deep_vellum_catalog,
    parse_catalog_args,
)

OUT_DIR = Path("priv/catalog_sources/real_publishers")
UA = "Hiraeth full catalog loader/1.0 (operator-authorized; local development)"
TODAY = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
RIGHTS = "Operator-authorized public catalog refresh from official publisher pages/APIs; factual bibliographic metadata, official product descriptions, official cover URLs, purchase links, and source provenance preserved for each field."
PROVIDERS = {
    "deep_vellum_official_store": {
        "file": "deep_vellum.json",
        "publisher": "Deep Vellum",
        "source_type": "publisher_dataset",
        "source_urls": ["https://store.deepvellum.org/products.json"],
        "source_hosts": ["store.deepvellum.org"],
        "cover_hosts": ["cdn.shopify.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://store.deepvellum.org/pages/contact-us",
    },
    "dalkey_archive_official_store": {
        "file": "dalkey_archive.json",
        "publisher": "Dalkey Archive",
        "source_type": "publisher_dataset",
        "source_urls": ["https://dalkeyarchive.store/products.json"],
        "source_hosts": ["dalkeyarchive.store"],
        "cover_hosts": ["cdn.shopify.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://dalkeyarchive.store/pages/contact",
    },
    "archipelago_books_official_store": {
        "file": "archipelago_books.json",
        "publisher": "Archipelago Books",
        "source_type": "publisher_dataset",
        "source_urls": ["https://archipelagobooks.org/wp-json/wc/store/products", "https://archipelagobooks.org/product-sitemap.xml"],
        "source_hosts": ["archipelagobooks.org"],
        "cover_hosts": ["archipelagobooks.org", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://archipelagobooks.org/contact/",
    },
    "new_directions_official_site": {
        "file": "new_directions.json",
        "publisher": "New Directions",
        "source_type": "publisher_official_page",
        "source_urls": ["https://www.ndbooks.com/sitemap-index.xml", "https://www.ndbooks.com/sitemap-0.xml", "https://www.ndbooks.com/books/"],
        "source_hosts": ["www.ndbooks.com"],
        "cover_hosts": ["cdn.sanity.io", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://www.ndbooks.com/about/contact/",
    },
    "transit_books_official_site": {
        "file": "transit_books.json",
        "publisher": "Transit Books",
        "source_type": "publisher_official_page",
        "source_urls": ["https://www.transitbooks.org/sitemap.xml", "https://www.transitbooks.org/books"],
        "source_hosts": ["www.transitbooks.org"],
        "cover_hosts": ["images.squarespace-cdn.com", "static1.squarespace.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://www.transitbooks.org/about",
    },
    "historical_materialism_official_site": {
        "file": "historical_materialism.json",
        "publisher": "Historical Materialism",
        "source_type": "publisher_official_page",
        "source_urls": ["https://www.historicalmaterialism.org/book-series/"],
        "source_hosts": ["www.historicalmaterialism.org"],
        "cover_hosts": ["www.historicalmaterialism.org", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://www.historicalmaterialism.org/contact/",
    },
    "semiotexte_official_site": {
        "file": "semiotexte.json",
        "publisher": "Semiotext(e)",
        "source_type": "publisher_official_page",
        "source_urls": ["https://www.semiotexte.com/books-1"],
        "source_hosts": ["www.semiotexte.com"],
        "cover_hosts": ["images.squarespace-cdn.com", "static1.squarespace.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://www.semiotexte.com/contact",
    },
    "phoneme_media_official_store": {
        "file": "phoneme_media.json",
        "publisher": "Phoneme Media",
        "source_type": "publisher_dataset",
        "source_urls": ["https://store.deepvellum.org/products.json"],
        "source_hosts": ["store.deepvellum.org"],
        "cover_hosts": ["cdn.shopify.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://store.deepvellum.org/pages/contact-us",
    },
    "a_strange_object_official_store": {
        "file": "a_strange_object.json",
        "publisher": "A Strange Object",
        "source_type": "publisher_dataset",
        "source_urls": ["https://store.deepvellum.org/products.json"],
        "source_hosts": ["store.deepvellum.org"],
        "cover_hosts": ["cdn.shopify.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://store.deepvellum.org/pages/contact-us",
    },
    "la_reunion_official_store": {
        "file": "la_reunion.json",
        "publisher": "La Reunion",
        "source_type": "publisher_dataset",
        "source_urls": ["https://store.deepvellum.org/products.json"],
        "source_hosts": ["store.deepvellum.org"],
        "cover_hosts": ["cdn.shopify.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://store.deepvellum.org/pages/contact-us",
    },
    "fum_destampa_official_store": {
        "file": "fum_destampa.json",
        "publisher": "Fum d'Estampa",
        "source_type": "publisher_dataset",
        "source_urls": ["https://store.deepvellum.org/products.json"],
        "source_hosts": ["store.deepvellum.org"],
        "cover_hosts": ["cdn.shopify.com", "covers.openlibrary.org"],
        "cover_policy": "cache_allowed",
        "takedown": "https://store.deepvellum.org/pages/contact-us",
    },
}

FORMAT_MAP = {
    "paperback": "paperback",
    "softcover": "paperback",
    "trade paperback": "paperback",
    "hardcover": "hardcover",
    "hardback": "hardcover",
    "ebook": "ebook",
    "e-book": "ebook",
    "epub": "ebook",
    "ebook (epub)": "ebook",
    "audio": "audiobook",
    "audio book": "audiobook",
    "audiobook": "audiobook",
}

MONTHS = {m.lower(): i for i, m in enumerate(["January","February","March","April","May","June","July","August","September","October","November","December"], 1)}
MONTHS.update({m[:3].lower(): i for m, i in MONTHS.copy().items()})


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=45) as response:
        return response.read()


def fetch_text(url: str) -> str:
    return fetch(url).decode("utf-8", "replace")


def fetch_json(url: str) -> Any:
    return json.loads(fetch_text(url))


def text_from_html(value: str | None) -> str:
    if not value:
        return ""
    value = re.sub(r"<script\b.*?</script>", " ", value, flags=re.I | re.S)
    value = re.sub(r"<style\b.*?</style>", " ", value, flags=re.I | re.S)
    value = re.sub(r"<br\s*/?>", "\n", value, flags=re.I)
    value = re.sub(r"</p\s*>", "\n", value, flags=re.I)
    value = re.sub(r"<[^>]+>", " ", value)
    value = html.unescape(value)
    value = re.sub(r"[ \t\r\f\v]+", " ", value)
    value = re.sub(r"\n\s*", "\n", value)
    return value.strip()


def compact(value: str | None) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def isbn13(value: Any) -> str | None:
    digits = re.sub(r"[^0-9Xx]", "", str(value or ""))
    if len(digits) != 13 or not digits.isdigit() or not digits.startswith(("978", "979")):
        return None
    nums = [int(ch) for ch in digits]
    check = (10 - (sum(n * (1 if i % 2 == 0 else 3) for i, n in enumerate(nums[:12])) % 10)) % 10
    return digits if check == nums[12] else None


def all_isbns(text: str) -> list[str]:
    found = []
    for match in re.finditer(r"97[89][\d\-\s]{10,20}", text or ""):
        isbn = isbn13(match.group(0))
        if isbn and isbn not in found:
            found.append(isbn)
    return found


def openlibrary_cover_url(isbn: str | None) -> str | None:
    if not isbn:
        return None
    url = f"https://covers.openlibrary.org/b/isbn/{isbn}-L.jpg?default=false"
    try:
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=8) as response:
            if response.status == 200 and (response.headers.get("content-type") or "").startswith("image/"):
                return url
    except Exception:
        return None
    return None


def attach_cover(record: dict[str, Any], provider: str, publisher: str, cover_url: str, source_uri: str, source_type: str) -> dict[str, Any]:
    record["cover"] = {
        "source_url": cover_url,
        "provider": provider,
        "rights_basis": "local_cache_permitted",
        "attribution_text": f"Cover via {publisher} official or authorized bibliographic source",
        "attribution_url": source_uri,
        "cache_policy": "cache_allowed",
    }
    record.pop("no_cover_reason", None)
    record.get("missing_fields", {}).pop("cover", None)
    if "cover" not in record["displayed_fields"]:
        record["displayed_fields"].append("cover")
    record["field_sources"]["cover"] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_type": source_type,
        "rights_basis": RIGHTS,
    }
    return record


def enrich_missing_covers(records: list[dict[str, Any]], provider: str) -> list[dict[str, Any]]:
    p = PROVIDERS[provider]
    fallback_by_title: dict[str, str] = {}
    for record in records:
        cover_url = ((record.get("cover") or {}).get("source_url"))
        if cover_url:
            fallback_by_title.setdefault(record["work"]["title"], cover_url)
    for record in records:
        if (record.get("cover") or {}).get("source_url"):
            continue
        isbn = record.get("edition", {}).get("isbn_13")
        cover_url = fallback_by_title.get(record["work"]["title"]) or openlibrary_cover_url(isbn)
        if cover_url:
            attach_cover(record, provider, p["publisher"], cover_url, record["source_uri"], p["source_type"])
    return records


def parse_date(value: str | None) -> str | None:
    value = compact(value)
    if not value:
        return None
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", value)
    if m:
        return m.group(0)
    m = re.search(r"(\d{1,2})/(\d{1,2})/(\d{4})", value)
    if m:
        mo, day, yr = map(int, m.groups())
        return f"{yr:04d}-{mo:02d}-{day:02d}"
    m = re.search(r"([A-Za-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})", value)
    if m and m.group(1).lower() in MONTHS:
        return f"{int(m.group(3)):04d}-{MONTHS[m.group(1).lower()]:02d}-{int(m.group(2)):02d}"
    m = re.search(r"([A-Za-z]+)\s+(\d{4})", value)
    if m and m.group(1).lower() in MONTHS:
        return f"{int(m.group(2)):04d}-{MONTHS[m.group(1).lower()]:02d}-01"
    return None


def normalize_format(value: str | None) -> str:
    v = compact(value).lower().replace("format", "").replace(":", "").strip()
    for key, fmt in FORMAT_MAP.items():
        if key in v:
            return fmt
    return "paperback"


def clean_title(title: str) -> str:
    title = html.unescape(compact(re.sub(r"\s+\|\s+.*$", "", title or "")))
    return title.strip(" -–—") or "Untitled"


def contributor(name: str, role: str = "author") -> dict[str, str] | None:
    name = compact(name)
    name = re.sub(r"^(by|edited by|translated by)\s+", "", name, flags=re.I).strip()
    name = re.sub(r"\s+\|\s+.*$", "", name).strip()
    name = re.sub(r"\s+-\s+Archipelago(?: Books)?$", "", name, flags=re.I).strip()
    name = re.sub(r"\s+Translated(?: from [^\n]+)? by .*$", "", name, flags=re.I).strip()
    name = re.sub(r"\s+Edited by .*$", "", name, flags=re.I).strip()
    name = re.sub(r"\s+(Paperback|Hardcover|eBook|ISBN|Publication Date).*$", "", name, flags=re.I).strip()
    name = name.strip(" \t\n\r\"“”'.,;:–—-")
    slug = re.sub(r"[^0-9A-Za-zÀ-ÖØ-öø-ÿ]+", "", name)
    prose_markers = re.compile(r"\b(represents|attempt|encounters|creates|evokes|providing|classic|collected|volume|include|readers|modern life|review|biography|confession)\b", re.I)
    if (
        not name
        or not slug
        or len(name) > 80
        or len(name.split()) > 4
        or not name[0].isupper()
        or "..." in name
        or prose_markers.search(name)
    ):
        return None
    return {"name": name, "role": role}


def contributors_from_text(text: str, fallback: str = "Unknown contributor") -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for pattern, role in [
        (r"\bBy\s+([^\n]+)", "author"),
        (r"\bPoetry by\s+([^\n]+)", "author"),
        (r"\bTranslated(?: from [^\n]+)? by\s+([^\n]+)", "translator"),
        (r"\bEdited by\s+([^\n]+)", "editor"),
    ]:
        m = re.search(pattern, text, re.I)
        if m:
            names = re.split(r"\s*(?:,| & | and )\s*", m.group(1))
            for name in names:
                item = contributor(name, role)
                if item and item not in out:
                    out.append(item)
    if not any(c["role"] == "author" for c in out):
        item = contributor(fallback, "author")
        if item:
            out.insert(0, item)
    return out[:6]


def title_author_from_shopify(product: dict[str, Any], body_text: str) -> tuple[str, str]:
    title = clean_title(product.get("title", ""))
    author = None
    m = re.search(r"\bBy\s+([^\n]+)", body_text, re.I)
    if m:
        author = compact(m.group(1))
    if not author and ":" in title:
        left, right = title.split(":", 1)
        if "," in left and len(right.strip()) > 3:
            parts = [p.strip() for p in left.split(",", 1)]
            author = f"{parts[1]} {parts[0]}".strip()
            title = clean_title(right.title() if right.isupper() else right)
    if author and ":" in title:
        left, right = title.split(":", 1)
        if compact(left).lower() == compact(author).lower() and len(right.strip()) > 3:
            title = clean_title(right.title() if right.isupper() else right)
    if author:
        title = clean_title(re.sub(rf"\s+by\s+{re.escape(author)}\s*$", "", title, flags=re.I))
    if not author and "," in title:
        left, right = title.rsplit(",", 1)
        if 2 <= len(right.strip().split()) <= 4 and len(left) > 3:
            title = clean_title(left)
            author = right.strip()
    return title, author or "Unknown contributor"


def description_from_text(text: str) -> str | None:
    lines = [compact(x) for x in re.split(r"\n+", text) if compact(x)]
    stop = re.compile(r"^(By |Translated |ISBN|Paperback|Hardcover|eBook|Publication Date|Reviews|Biographical|Price|Page Count|SKU|Category|Tags)", re.I)
    candidates = [x for x in lines if len(x) > 80 and not stop.search(x)]
    if not candidates:
        return None
    desc = candidates[0]
    return desc[:900].strip()


def field_sources(provider: str, source_uri: str, fields: list[str], source_type: str) -> dict[str, dict[str, str]]:
    return {
        field: {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": source_type,
            "rights_basis": RIGHTS,
        }
        for field in fields
    }


def make_record(provider: str, publisher: str, source_type: str, source_uri: str, source_product_id: str,
                title: str, fmt: str, isbn: str | None, contributors: list[dict[str, str]],
                cover_url: str | None, published_on: str | None, description: str | None,
                subjects: list[str] | None = None, editorial_praise: list[dict[str, str]] | None = None) -> dict[str, Any]:
    displayed = ["title", "contributors", "publisher", "format"]
    missing = {}
    if published_on:
        displayed.append("published_on")
    else:
        missing["published_on"] = "not present in source record"
    if isbn:
        displayed.append("isbn_13")
    else:
        missing["isbn_13"] = "not present in source record"
    cover = None
    if cover_url and cover_url.startswith("//"):
        cover_url = "https:" + cover_url
    if cover_url and cover_url.startswith("http://static1.squarespace.com"):
        cover_url = "https://static1.squarespace.com" + urllib.parse.urlparse(cover_url).path + (('?' + urllib.parse.urlparse(cover_url).query) if urllib.parse.urlparse(cover_url).query else '')
    if cover_url and cover_url.startswith("https://"):
        displayed.append("cover")
        cover = {
            "source_url": cover_url,
            "provider": provider,
            "rights_basis": "local_cache_permitted",
            "attribution_text": f"Cover via {publisher} official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        }
    else:
        missing["cover"] = "not present in source record"
    if description:
        displayed.append("description")
    else:
        missing["description"] = "not present in source record"
    displayed.append("storefront_url")
    if subjects:
        displayed.append("subjects")
    if editorial_praise:
        displayed.append("editorial_praise")
    rec = {
        "source_uri": source_uri,
        "source_product_id": source_product_id,
        "source_sku": isbn,
        "publisher": publisher,
        "imprint": None,
        "work": {"title": title, "subtitle": None, "original_title": None, "publication_state": "published"},
        "edition": {"title": title, "subtitle": None, "format": fmt, "published_on": published_on, "isbn_13": isbn},
        "contributors": contributors or [{"name": "Unknown contributor", "role": "author"}],
        "displayed_fields": displayed,
        "curation": {"status": "approved", "notes": "Operator-authorized full-catalog refresh from public source; generated deterministically with field provenance."},
        "storefront_url": source_uri,
        "field_sources": field_sources(provider, source_uri, displayed, source_type),
    }
    if cover:
        rec["cover"] = cover
    else:
        rec["no_cover_reason"] = missing["cover"]
    if description:
        rec["description"] = description
    if subjects:
        rec["work"]["subjects"] = subjects[:12]
    if editorial_praise:
        rec["editorial_praise"] = editorial_praise[:8]
    if missing:
        rec["missing_fields"] = missing
    return rec


def permission_meta(provider: str) -> dict[str, Any]:
    p = PROVIDERS[provider]
    return {
        "provider": provider,
        "source_urls": p["source_urls"],
        "source_hosts": p["source_hosts"],
        "cover_hosts": p["cover_hosts"],
        "permission_basis": RIGHTS,
        "cover_cache_policy": p["cover_policy"],
        "excluded_content": ["cart_checkout_account", "inventory_state", "user_reviews", "raw_html_without_sanitization"],
        "takedown_contact": p["takedown"],
        "not_legal_advice": "Operator-authorized ingestion policy and provenance metadata; not legal advice.",
    }


def dataset(provider: str, records: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "provider": provider,
        "retrieved_at": TODAY,
        "license_note": RIGHTS,
        "provider_permissions": permission_meta(provider),
        "records": records,
    }


def shopify_products(base: str) -> list[dict[str, Any]]:
    products = []
    for page in range(1, 100):
        url = f"{base}?limit=250&page={page}"
        batch = fetch_json(url).get("products", [])
        if not batch:
            break
        products.extend(batch)
        time.sleep(0.05)
    return products


def build_shopify(provider: str, allowed_vendors: set[str]) -> list[dict[str, Any]]:
    p = PROVIDERS[provider]
    base = p["source_urls"][0]
    records = []
    for product in shopify_products(base):
        if product.get("vendor") not in allowed_vendors:
            continue
        body_text = text_from_html(product.get("body_html"))
        title, fallback_author = title_author_from_shopify(product, body_text)
        contributors = contributors_from_text(body_text, fallback_author)
        desc = description_from_text(body_text)
        date = parse_date(body_text) or parse_date(product.get("published_at"))
        cover = (product.get("images") or [{}])[0].get("src")
        subjects = [str(t) for t in product.get("tags", []) if str(t).strip() and not str(t).startswith("import_")]
        seen = set()
        for variant in product.get("variants", []) or []:
            isbn = isbn13(variant.get("sku"))
            if not isbn or isbn in seen:
                continue
            seen.add(isbn)
            fmt = normalize_format(variant.get("title") or variant.get("option1") or body_text)
            source_uri = f"https://{urllib.parse.urlparse(base).hostname}/products/{product.get('handle')}"
            records.append(make_record(provider, p["publisher"], p["source_type"], source_uri, f"{product.get('id')}-{variant.get('id')}", title, fmt, isbn, contributors, cover, date, desc, subjects))
    return records


def build_deep_vellum() -> list[dict[str, Any]]:
    return build_deep_vellum_catalog(
        PROVIDERS[DEEP_VELLUM_PROVIDER],
        make_record,
        normalize_format,
        isbn13,
        parse_date,
        build_shopify,
    )


def build_archipelago() -> list[dict[str, Any]]:
    provider = "archipelago_books_official_store"; p = PROVIDERS[provider]
    products = []
    for page in range(1, 20):
        batch = fetch_json(f"https://archipelagobooks.org/wp-json/wc/store/products?per_page=100&page={page}")
        if not batch:
            break
        products.extend(batch)
    records = []
    for product in products:
        cats = {c.get("slug") for c in product.get("categories", [])}
        tags = {t.get("slug") for t in product.get("tags", [])}
        if "books" not in cats or "bundle" in cats or "bundle" in tags:
            continue
        page_url = product.get("permalink")
        try:
            page_html = fetch_text(page_url)
        except Exception:
            page_html = ""
        page_text = text_from_html(page_html)
        isbn_pairs = []
        for m in re.finditer(r"([A-Za-z ()]+?)\s+ISBN:\s*(97[89][\d\-\s]{10,20})", page_text, re.I):
            isbn = isbn13(m.group(2)); fmt = normalize_format(m.group(1))
            if isbn and (isbn, fmt) not in isbn_pairs:
                isbn_pairs.append((isbn, fmt))
        if not isbn_pairs:
            for isbn in all_isbns(page_text + " " + json.dumps(product))[:1]:
                isbn_pairs.append((isbn, "paperback"))
        if not isbn_pairs:
            continue
        contributors = contributors_from_text(page_text, "Unknown contributor")
        date = None
        m = re.search(r"Published:\s*([^\n]+?)(?:\s+(?:Paperback|Hardcover|ebook|eBook)|$)", page_text, re.I)
        if m: date = parse_date(m.group(1))
        desc = description_from_text(text_from_html(product.get("description"))) or description_from_text(page_text)
        cover = (product.get("images") or [{}])[0].get("src")
        subjects = [t.get("name") for t in product.get("tags", []) if t.get("name")]
        for isbn, fmt in isbn_pairs:
            records.append(make_record(provider, p["publisher"], p["source_type"], page_url, f"{product.get('id')}-{isbn}", clean_title(product.get("name")), fmt, isbn, contributors, cover, date, desc, subjects))
        time.sleep(0.03)
    return records


def ld_json_objects(text: str) -> list[Any]:
    out = []
    for m in re.finditer(r"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>", text, re.I | re.S):
        raw = html.unescape(m.group(1)).strip()
        try:
            out.append(json.loads(raw))
        except Exception:
            continue
    return out


def transit_listing_index() -> dict[str, dict[str, str]]:
    page = fetch_text("https://www.transitbooks.org/books")
    index = {}
    blocks = re.findall(r"<div class=\"ProductList-item\b.*?(?=<div class=\"ProductList-item\b|<footer)", page, re.I | re.S)
    for block in blocks:
        href_match = re.search(r"href=[\"']([^\"']*/books/[^\"']+)[\"']", block)
        title_match = re.search(r"<h1 class=\"ProductList-title\">(.*?)</h1>", block, re.I | re.S)
        if not href_match or not title_match:
            continue
        href = urllib.parse.urljoin("https://www.transitbooks.org/books", html.unescape(href_match.group(1)))
        title = clean_title(text_from_html(title_match.group(1)))
        cover_match = re.search(r"data-image=[\"']([^\"']+)[\"']", block) or re.search(r"data-src=[\"']([^\"']+)[\"']", block)
        index[href] = {"title": title}
        if cover_match:
            index[href]["cover"] = html.unescape(cover_match.group(1))
    return index


def transit_clean_product_title(name: str, listed_title: str | None = None) -> tuple[str, str | None]:
    title = compact(name.replace("Transit Books —", ""))
    author = None
    if " by " in title:
        title, author = title.rsplit(" by ", 1)
    if " | " in title:
        title, author = title.split(" | ", 1)
    return clean_title(listed_title or title), author and compact(author)


def transit_product_details_text(page: str) -> str:
    start = page.find("ProductItem-details")
    if start < 0:
        return text_from_html(page)
    end = page.find("<footer", start)
    value = page[start:end if end > start else start + 40_000]
    value = re.sub(r"</(h\d|div|section)\s*>", "\n", value, flags=re.I)
    return text_from_html(value)


def transit_leading_author(text: str) -> str | None:
    text = compact(re.sub(r"^.*?\$\d+(?:\.\d{2})?\s+", "", text))
    markers = [
        r"\s+Translated\b",
        r"\s+Introduction\b",
        r"\s+WINNER\b",
        r"\s+Winner\b",
        r"\s+Longlisted\b",
        r"\s+Shortlisted\b",
        r"\s+A\s+[a-z]",
        r"\s+An\s+[a-z]",
        r"\s+The\s+[a-z]",
        r"\s+In\s+[A-Z]",
        r"\s+Stories\s+from\b",
        r"\s+Every\s+child\b",
        r"\s+No\s+one\b",
    ]
    indexes = []
    for marker in markers:
        found = re.search(marker, text)
        if found and found.start() > 2:
            indexes.append(found.start())
    candidate = text[: min(indexes)] if indexes else text.split(". ", 1)[0]
    item = contributor(candidate, "author")
    if item and candidate.isupper():
        return item["name"].title()
    return item and item["name"]


def transit_contributors(product_name: str, description: str, details: str) -> list[dict[str, str]]:
    _title, title_author = transit_clean_product_title(product_name)
    author = title_author or transit_leading_author(details) or transit_leading_author(description)
    output = []
    item = contributor(author or "Unknown contributor", "author")
    if item:
        output.append(item)
    for translator_name in transit_translator_names(details):
        translator = contributor(translator_name, "translator")
        if translator and translator not in output:
            output.append(translator)
    return output or [{"name": "Unknown contributor", "role": "author"}]


def transit_translator_names(text: str) -> list[str]:
    names = []
    marker_tokens = {
        "A", "An", "By", "Every", "Fiction", "Hardcover", "In", "No", "Paperback",
        "Product", "Rights", "Stories", "The", "WINNER", "Winner",
    }
    pattern = re.compile(r"Translated(?: from (?:the )?[A-Za-z]+)? by\s+(.+)", re.I)
    for match in pattern.finditer(text):
        tokens = []
        for token in re.split(r"\s+", match.group(1).strip()):
            cleaned = token.strip(",;:()[]")
            if (
                not cleaned
                or cleaned in marker_tokens
                or cleaned.isdigit()
                or (cleaned.isupper() and len(cleaned) > 1 and not re.fullmatch(r"[A-Z]\.", cleaned))
            ):
                break
            tokens.append(cleaned)
            if len(tokens) >= 4:
                break
        name = compact(" ".join(tokens)).strip(".,;: ")
        if name and name not in names:
            names.append(name)
    return names


def transit_publication_date(details: str) -> str | None:
    match = re.search(r"Publication Date:\s*([^\n]+)", details, re.I)
    if match:
        return parse_date(match.group(1))
    return None


def transit_subjects(details: str) -> list[str] | None:
    subjects = []
    for line in [compact(line) for line in details.splitlines()]:
        if line in {"Fiction", "Nonfiction", "Poetry", "Essays", "Undelivered Lectures"}:
            subjects.append(line)
    return subjects or None


def transit_format(details: str) -> str:
    match = re.search(r"(Paperback|Hardcover|Ebook|Audiobook)\s*\|", details, re.I)
    return normalize_format(match.group(1) if match else details)


def transit_description(description: str, contributors: list[dict[str, str]]) -> str | None:
    value = description
    for item in contributors:
        value = re.sub(rf"^\s*{re.escape(item['name'])}\s*", "", value, flags=re.I)
    value = re.sub(
        r"^\s*Translated(?: from (?:the )?[A-Za-z]+)? by\s+[A-Z][A-Za-zÀ-ÖØ-öø-ÿ.'-]*(?:\s+[A-Z][A-Za-zÀ-ÖØ-öø-ÿ.'-]*){0,3}\s*",
        "",
        value,
        flags=re.I,
    )
    value = compact(value)
    return value[:900] if len(value) > 40 else None


def transit_editorial_praise(details: str, source_uri: str) -> list[dict[str, str]]:
    praise = []
    section = re.split(r"\bPraise for\b", details, flags=re.I)
    if len(section) < 2:
        return praise
    for quote, source in re.findall(r"[“\"]([^”\"]{20,260})[”\"].{0,40}?—\s*([^\n\"]{2,80})", section[1]):
        praise.append({"quote": compact(quote)[:280], "source": compact(source), "source_uri": source_uri})
    return praise[:6]


def build_new_directions() -> list[dict[str, Any]]:
    provider = "new_directions_official_site"; p = PROVIDERS[provider]
    sitemap = fetch_text("https://www.ndbooks.com/sitemap-0.xml")
    urls = sorted(set(u for u in re.findall(r"<loc>(.*?)</loc>", sitemap) if "/book/" in u and u.rstrip("/") != "https://www.ndbooks.com/book"))
    records = []
    for idx, url in enumerate(urls, 1):
        try:
            page = fetch_text(url)
        except Exception:
            continue
        book = None
        for obj in ld_json_objects(page):
            objs = obj.get("@graph", []) if isinstance(obj, dict) and "@graph" in obj else [obj]
            for candidate in objs:
                if isinstance(candidate, dict) and candidate.get("@type") == "Book":
                    book = candidate; break
            if book: break
        if not book:
            continue
        title = clean_title((book.get("name") or "").replace("| New Directions Publishing", ""))
        primary = isbn13(book.get("isbn"))
        examples = book.get("workingExample") or []
        pairs = []
        if primary:
            pairs.append((primary, normalize_format(str(book.get("bookFormat") or "paperback"))))
        for ex in examples if isinstance(examples, list) else [examples]:
            if isinstance(ex, dict):
                isbn = isbn13(ex.get("isbn")); fmt = normalize_format(str(ex.get("bookFormat") or ex.get("name") or "ebook"))
                if isbn and (isbn, fmt) not in pairs:
                    pairs.append((isbn, fmt))
        if not pairs:
            continue
        plain = text_from_html(page)
        contribs = contributors_from_text(plain, "Unknown contributor")
        date = None
        m = re.search(r"Available\s+([A-Za-z]+\s+\d{1,2},\s+\d{4})", plain)
        if m: date = parse_date(m.group(1))
        if not date:
            m = re.search(r"published:\s*([^\n]+)", plain, re.I)
            if m: date = parse_date(m.group(1))
        desc = compact(book.get("description") or "")[:900] or description_from_text(plain)
        image = book.get("image")
        cover = image[0] if isinstance(image, list) and image else image if isinstance(image, str) else None
        if cover and not str(cover).startswith("https://cdn.sanity.io/"):
            cover = None
        if not cover:
            m = re.search(r"https://cdn\.sanity\.io/[^\"'<> ]+", page)
            if m:
                cover = html.unescape(m.group(0))
        for isbn, fmt in pairs:
            records.append(make_record(provider, p["publisher"], p["source_type"], url, f"{url.rstrip('/').split('/')[-1]}-{isbn}", title, fmt, isbn, contribs, cover, date, desc, None))
        if idx % 50 == 0:
            print(f"new_directions {idx}/{len(urls)}", file=sys.stderr)
        time.sleep(0.02)
    return records


def build_transit() -> list[dict[str, Any]]:
    provider = "transit_books_official_site"; p = PROVIDERS[provider]
    sitemap = fetch_text("https://www.transitbooks.org/sitemap.xml")
    listing = transit_listing_index()
    urls = sorted(set(u for u in re.findall(r"<loc>(.*?)</loc>", sitemap) if "/books/" in u) | set(listing))
    skip_terms = ["sticker", "shirt", "hats", "club", "subscription", "merch", "broadside"]
    records = []
    for url in urls:
        slug = url.rsplit("/", 1)[-1].lower()
        listed = listing.get(url, {})
        listed_title = listed.get("title")
        if any(term in slug for term in skip_terms) or any(term in (listed_title or "").lower() for term in skip_terms):
            continue
        try:
            page = fetch_text(url)
        except Exception:
            continue
        product = None
        for obj in ld_json_objects(page):
            objs = obj.get("@graph", []) if isinstance(obj, dict) and "@graph" in obj else [obj]
            for candidate in objs:
                if isinstance(candidate, dict) and candidate.get("@type") == "Product" and candidate.get("offers"):
                    product = candidate; break
            if product: break
        if not product:
            continue
        offers = product.get("offers") or {}
        isbn = isbn13(offers.get("sku"))
        if not isbn:
            continue
        title, _title_author = transit_clean_product_title(str(product.get("name") or ""), listed_title)
        desc = compact(product.get("description") or "")
        details = transit_product_details_text(page)
        contribs = transit_contributors(str(product.get("name") or ""), desc, details)
        description = transit_description(desc, contribs) or description_from_text(details)
        cover = listed.get("cover") or product.get("image")
        date = transit_publication_date(details)
        subjects = transit_subjects(details)
        praise = transit_editorial_praise(details, url)
        records.append(make_record(provider, p["publisher"], p["source_type"], url, f"{slug}-{isbn}", title, transit_format(details), isbn, contribs, cover, date, description, subjects, praise))
        time.sleep(0.03)
    return records


def historical_materialism_index_urls() -> list[str]:
    urls: list[str] = []
    for page_number in range(1, 80):
        url = (
            "https://www.historicalmaterialism.org/book-series/"
            if page_number == 1
            else f"https://www.historicalmaterialism.org/book-series/page/{page_number}/"
        )
        try:
            page = fetch_text(url)
        except Exception:
            break
        blocks = re.findall(r"<article\b.*?</article>", page, re.I | re.S)
        if not blocks:
            break
        for block in blocks:
            match = re.search(r"<a[^>]+href=[\"']([^\"']+/book-series/[^\"']+)[\"']", block, re.I)
            if match:
                source_uri = html.unescape(match.group(1))
                if source_uri not in urls:
                    urls.append(source_uri)
        if not re.search(rf"/book-series/page/{page_number + 1}/", page):
            if page_number > 1:
                break
        time.sleep(0.05)
    return urls


def historical_materialism_contributors(page: str) -> list[dict[str, str]]:
    output: list[dict[str, str]] = []
    for role_label, role in [("Author", "author"), ("Editor", "editor")]:
        for name in re.findall(
            rf'<span class="creator-type-label">{role_label}:</span>.*?<span[^>]*data-testid="{role}-name"[^>]*>(.*?)</span>',
            page,
            re.I | re.S,
        ):
            item = contributor(text_from_html(name), role)
            if item and item not in output:
                output.append(item)
    if output:
        return output[:6]

    meta = ""
    match = re.search(r'<meta property="og:description" content="([^"]*)"', page, re.I)
    if match:
        meta = html.unescape(match.group(1))
    match = re.search(r"\b(?:Author|Editor):\s*([^.;\n]+)", meta, re.I)
    item = contributor(match.group(1), "author") if match else None
    return [item] if item else [{"name": "Unknown contributor", "role": "author"}]


def historical_materialism_description(page: str) -> str | None:
    match = re.search(
        r'<div[^>]+class="[^"]*\babstract\b[^"]*"[^>]*>(.*?)</div>',
        page,
        re.I | re.S,
    )
    if match:
        return compact(text_from_html(match.group(1)))[:900]
    match = re.search(r'<meta property="og:description" content="([^"]*)"', page, re.I)
    if match:
        desc = compact(re.sub(r"\b(?:Author|Editor):\s*[^.]+", "", html.unescape(match.group(1))))
        return desc[:900] if len(desc) > 40 else None
    return None


def build_historical_materialism() -> list[dict[str, Any]]:
    provider = "historical_materialism_official_site"
    p = PROVIDERS[provider]
    records: list[dict[str, Any]] = []
    urls = historical_materialism_index_urls()
    for idx, url in enumerate(urls, 1):
        try:
            page = fetch_text(url)
        except Exception:
            continue
        title_match = re.search(r"<h1[^>]*>(.*?)</h1>", page, re.I | re.S)
        title = clean_title(text_from_html(title_match.group(1)) if title_match else "")
        if not title:
            title = clean_title(url.rstrip("/").rsplit("/", 1)[-1].replace("-", " "))
        cover_match = re.search(r'<meta property="og:image" content="([^"]+)"', page, re.I)
        cover = html.unescape(cover_match.group(1)) if cover_match else None
        date = None
        date_match = re.search(r"<div class=\"meta-info\">Published\s+([^<]+)</div>", page, re.I)
        if date_match:
            date = parse_date(date_match.group(1))
        record = make_record(
            provider,
            p["publisher"],
            p["source_type"],
            url,
            url.rstrip("/").rsplit("/", 1)[-1],
            title,
            "hardcover" if "Buy hardcover" in page else "paperback",
            None,
            historical_materialism_contributors(page),
            cover,
            date,
            historical_materialism_description(page),
            ["Marxism", "Critical Theory", "Historical Materialism"],
        )
        records.append(record)
        if idx % 50 == 0:
            print(f"historical_materialism {idx}/{len(urls)}", file=sys.stderr)
        time.sleep(0.05)
    return records


def semiotexte_listing_blocks() -> list[str]:
    page = fetch_text("https://www.semiotexte.com/books-1")
    return re.findall(r'<li\b[^>]*class="[^"]*list-item[^"]*".*?</li>', page, re.I | re.S)


def semiotexte_record_from_block(block: str) -> dict[str, Any] | None:
    provider = "semiotexte_official_site"
    p = PROVIDERS[provider]
    href_match = re.search(r'<a[^>]+href="([^"]+)"', block, re.I)
    desc_match = re.search(
        r'<div class="list-item-content__description[^"]*"[^>]*>(.*?)</div>',
        block,
        re.I | re.S,
    )
    if not href_match or not desc_match:
        return None
    source_uri = urllib.parse.urljoin("https://www.semiotexte.com/books-1", html.unescape(href_match.group(1)))
    description_html = desc_match.group(1)
    title_match = re.search(r"<strong>(.*?)</strong>", description_html, re.I | re.S)
    title = clean_title(text_from_html(title_match.group(1)) if title_match else "")
    if not title:
        title = clean_title(source_uri.rstrip("/").rsplit("/", 1)[-1].replace("-", " "))

    lines = [compact(line) for line in text_from_html(description_html).splitlines() if compact(line)]
    people_lines = [line for line in lines[1:] if not re.match(r"^(Translated|With|Edited)\b", line, re.I)]
    contributors: list[dict[str, str]] = []
    for line in people_lines[:3]:
        for name in re.split(r"\s*(?:,| and | & )\s*", line):
            item = contributor(name, "author")
            if item and item not in contributors:
                contributors.append(item)
    translated = re.search(r"Translated(?: from [^ ]+)? by\s+(.+)", text_from_html(description_html), re.I)
    if translated:
        for name in re.split(r"\s*(?:,| and | & )\s*", translated.group(1)):
            item = contributor(name, "translator")
            if item and item not in contributors:
                contributors.append(item)
    image_match = re.search(r'data-image="([^"]+)"', block, re.I)
    cover = html.unescape(image_match.group(1)) if image_match else None
    detail_blocks = semiotexte_detail_blocks(source_uri)
    detail_text = "\n".join(detail_blocks)
    detail_description = semiotexte_detail_description(detail_blocks)
    detail_contributors = contributors_from_text(detail_text, contributors[0]["name"] if contributors else "Unknown contributor")
    detail_date = parse_date(detail_text)
    return make_record(
        provider,
        p["publisher"],
        p["source_type"],
        source_uri,
        source_uri.rstrip("/").rsplit("/", 1)[-1],
        title.title() if title.isupper() else title,
        "paperback",
        None,
        detail_contributors or contributors or [{"name": "Unknown contributor", "role": "author"}],
        cover,
        detail_date,
        detail_description,
        ["Theory", "Semiotext(e)"],
    )


def semiotexte_detail_blocks(source_uri: str) -> list[str]:
    try:
        page = fetch_text(source_uri)
    except (urllib.error.HTTPError, urllib.error.URLError):
        return []
    blocks = []
    for match in re.finditer(r'<div class="sqs-html-content"[^>]*>(.*?)</div>', page, re.I | re.S):
        block = re.sub(r"<br\s*/?>", "\n", match.group(1), flags=re.I)
        value = compact(text_from_html(block))
        if value:
            blocks.append(value)
    return blocks


def semiotexte_detail_description(blocks: list[str]) -> str | None:
    for block in blocks:
        if len(block) <= 120:
            continue
        description = re.sub(r"^(By|Edited by|Translated by|Preface by|With)\s+.+?(?=\b[A-Z][a-z]{2,}\b)", "", block).strip()
        return description[:900].strip() or block[:900].strip()
    return None


def build_semiotexte() -> list[dict[str, Any]]:
    records = []
    for block in semiotexte_listing_blocks():
        record = semiotexte_record_from_block(block)
        if record:
            records.append(record)
        time.sleep(0.03)
    return records


def dedupe(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen = set(); out = []
    for r in records:
        key = r["edition"].get("isbn_13") or r["source_product_id"]
        if key in seen:
            continue
        seen.add(key); out.append(r)
    return out


def catalog_builders() -> dict[str, Callable[[], list[dict[str, Any]]]]:
    return {
        "deep_vellum_official_store": build_deep_vellum,
        "dalkey_archive_official_store": lambda: build_shopify("dalkey_archive_official_store", {"Dalkey Archive Press"}),
        "archipelago_books_official_store": build_archipelago,
        "new_directions_official_site": build_new_directions,
        "transit_books_official_site": build_transit,
        "historical_materialism_official_site": build_historical_materialism,
        "semiotexte_official_site": build_semiotexte,
        "phoneme_media_official_store": lambda: build_shopify("phoneme_media_official_store", {"Phoneme", "Phoneme Media"}),
        "a_strange_object_official_store": lambda: build_shopify("a_strange_object_official_store", {"A Strange Object"}),
        "la_reunion_official_store": lambda: build_shopify("la_reunion_official_store", {"La Reunion"}),
        "fum_destampa_official_store": lambda: build_shopify("fum_destampa_official_store", {"Fum d'Estampa", "Fum d’Estampa"}),
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_catalog_args(PROVIDERS, argv)
    if not args.dry_run:
        OUT_DIR.mkdir(parents=True, exist_ok=True)

    builders = catalog_builders()
    selected = [args.provider] if args.provider else list(builders)
    summary = {}
    for provider in selected:
        build = builders[provider]
        print(f"building {provider}", file=sys.stderr)
        records = enrich_missing_covers(dedupe(build()), provider)
        records.sort(key=lambda r: (r["work"]["title"].lower(), r["edition"].get("format") or "", r["edition"].get("isbn_13") or ""))
        path = OUT_DIR / str(PROVIDERS[provider]["file"])
        summary[provider] = len(records)
        if args.dry_run:
            print(f"dry-run {provider} output={path} records={len(records)}", file=sys.stderr)
        else:
            path.write_text(json.dumps(dataset(provider, records), ensure_ascii=False, indent=2) + "\n")
            print(f"wrote {path} records={len(records)}", file=sys.stderr)
    print(json.dumps({"retrieved_at": TODAY, "records": summary, "total": sum(summary.values())}, indent=2))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
