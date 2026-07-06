# /// script
# requires-python = ">=3.11"
# dependencies = ["scrapling", "curl-cffi", "playwright", "browserforge"]
# ///
"""Extract Fitzcarraldo Editions catalog records with Scrapling."""
from __future__ import annotations

import html
import json
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from scrapling.fetchers import Fetcher

OUT = Path("priv/catalog_sources/real_publishers/fitzcarraldo_editions.json")
PROVIDER = "fitzcarraldo_editions_official_site"
PUBLISHER = "Fitzcarraldo Editions"
SOURCE_TYPE = "publisher_official_page"
UA = "Hiraeth Fitzcarraldo extractor/1.0 (operator-authorized; local development)"
RIGHTS = (
    "Operator-authorized public catalog refresh from official publisher pages/APIs; "
    "factual bibliographic metadata, official product descriptions, official cover URLs, "
    "purchase links, and source provenance preserved for each field."
)
CATEGORIES = [
    ("fiction", "Fitzcarraldo Editions Fiction", "fitzcarraldo-editions-fiction", "Fiction"),
    ("essays", "Fitzcarraldo Editions Essays", "fitzcarraldo-editions-essays", "Essays"),
    ("poetry", "Fitzcarraldo Editions Poetry", "fitzcarraldo-editions-poetry", "Poetry"),
]
MONTHS = {m.lower(): i for i, m in enumerate(
    "January February March April May June July August September October November December".split(), 1
)}


@dataclass(frozen=True)
class ListedBook:
    url: str
    title: str
    author: str | None
    cover: str | None
    category_slug: str
    series_title: str
    series_slug: str
    subject: str
    position: int

def fetch(url: str):
    return Fetcher.get(url, headers={"User-Agent": UA})

def clean(text: object | None) -> str | None:
    if text is None:
        return None
    value = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html.unescape(str(text)))).strip()
    return value or None

def tail(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1]


def parse_date(text: str | None) -> str | None:
    match = re.search(r"Published\s+(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})", text or "")
    if not match:
        return None
    day, month, year = match.groups()
    month_number = MONTHS.get(month.lower())
    return f"{int(year):04d}-{month_number:02d}-{int(day):02d}" if month_number else None


def page_count(details: str | None) -> int | None:
    match = re.search(r"(\d{2,4})\s+pages", details or "", re.I)
    return int(match.group(1)) if match else None


def listing_books(category_slug: str, series_title: str, series_slug: str, subject: str) -> list[ListedBook]:
    page = fetch(f"https://fitzcarraldoeditions.com/shop/{category_slug}/")
    books: list[ListedBook] = []
    seen: set[str] = set()
    for item in page.css("a.publication"):
        href = item.attrib.get("href")
        title = clean(item.css(".publication__overlay--title span::text").get())
        if not href or href in seen or not title:
            continue
        seen.add(href)
        image = item.css("img")
        books.append(ListedBook(
            url=href,
            title=title,
            author=clean(item.css(".publication__overlay--author::text").get()),
            cover=cover_url(image[0]) if image else None,
            category_slug=category_slug,
            series_title=series_title,
            series_slug=series_slug,
            subject=subject,
            position=len(books) + 1,
        ))
    return books



def cover_url(image) -> str | None:
    srcset = image.attrib.get("srcset") or image.attrib.get("data-srcset") or ""
    match = re.search(r"https://[^,\s]+", srcset)
    return match.group(0) if match else image.attrib.get("src")

def detail_metadata(listed: ListedBook) -> dict[str, object | None]:
    page = fetch(listed.url)
    texts = [text for text in (clean(t) for t in page.css("main *::text").getall()) if text]
    body = page.body.decode() if isinstance(page.body, bytes) else str(page.body)
    collaborator = clean(page.css("p.collaborator")[0].get_all_text() if page.css("p.collaborator") else None)
    details = next((t for t in texts if "pages" in t.lower() and "published" not in t.lower()), None)
    ebook_isbns = sorted(set(re.findall(r"(?:isbn|query=)(97[89][0-9]{10})", body)))
    return {
        "title": clean(page.css("h1.book-title::text").get()) or listed.title,
        "author": clean(page.css("p.author a::text").get()) or listed.author,
        "collaborator": collaborator,
        "details": details,
        "published_on": parse_date(next((t for t in texts if t.startswith("Published ")), None)),
        "page_count": page_count(details),
        "description": clean(page.css('meta[property="og:description"]::attr(content)').get()),
        "cover": listed.cover or clean(page.css('meta[property="og:image"]::attr(content)').get()),
        "ebook_isbn": ebook_isbns[0] if ebook_isbns else None,
    }


def contributors(author: object | None, collaborator: object | None) -> list[dict[str, str]]:
    people = [{"name": str(author), "role": "author"}] if author else []
    text = str(collaborator or "")
    if "translated by" in text.lower():
        names = re.sub(r"^translated\s+by\s+", "", text, flags=re.I)
        people += [{"name": name, "role": "translator"} for name in map(clean, re.split(r"\s+and\s+|,", names)) if name]
    return people


def field_source(source_uri: str) -> dict[str, str]:
    return {"provider": PROVIDER, "source_uri": source_uri, "source_type": SOURCE_TYPE, "rights_basis": RIGHTS}


def record(listed: ListedBook, meta: dict[str, object | None], fmt: str, isbn: str | None) -> dict[str, object]:
    title = str(meta["title"])
    displayed = ["title", "contributors", "publisher", "format", "cover", "description", "storefront_url", "subjects"]
    edition: dict[str, object] = {"title": title, "subtitle": None, "format": fmt}
    for key in ["published_on", "page_count"]:
        if meta.get(key) and (key != "page_count" or fmt == "paperback"):
            edition[key] = meta[key]
            displayed.append(key)
    if isbn:
        edition["isbn_13"] = isbn
        displayed.append("isbn_13")
    result: dict[str, object] = {
        "source_uri": listed.url,
        "source_product_id": f"{tail(listed.url)}-{fmt}",
        "source_sku": isbn,
        "publisher": PUBLISHER,
        "imprint": None,
        "work": {"title": title, "subtitle": None, "original_title": None, "publication_state": "published", "subjects": [listed.subject]},
        "edition": edition,
        "contributors": contributors(meta.get("author"), meta.get("collaborator")),
        "displayed_fields": displayed,
        "curation": {"status": "approved", "notes": "Operator-authorized full-catalog refresh from public source; generated deterministically with field provenance."},
        "storefront_url": listed.url,
        "field_sources": {field: field_source(listed.url) for field in displayed},
        "cover": {"source_url": meta["cover"], "provider": PROVIDER, "rights_basis": "local_cache_permitted", "attribution_text": "Cover via Fitzcarraldo Editions official source", "attribution_url": listed.url, "cache_policy": "cache_allowed"},
        "description": meta["description"],
        "series": [{"title": listed.series_title, "slug": listed.series_slug, "position": listed.position, "label": str(listed.position), "source_uri": f"https://fitzcarraldoeditions.com/shop/{listed.category_slug}/"}],
    }
    if not isbn:
        result["missing_fields"] = {"isbn_13": "Official Fitzcarraldo book page did not expose an ISBN for this format."}
    return result



def remove_duplicate_isbns(records: list[dict[str, object]]) -> list[dict[str, object]]:
    seen: set[str] = set()
    for record in records:
        edition = record.get("edition")
        if not isinstance(edition, dict):
            continue
        isbn = edition.get("isbn_13")
        if not isinstance(isbn, str) or isbn not in seen:
            if isinstance(isbn, str):
                seen.add(isbn)
            continue
        edition.pop("isbn_13", None)
        record["source_sku"] = None
        if isinstance(record.get("displayed_fields"), list):
            record["displayed_fields"] = [field for field in record["displayed_fields"] if field != "isbn_13"]
        if isinstance(record.get("field_sources"), dict):
            record["field_sources"].pop("isbn_13", None)
        record["missing_fields"] = {"isbn_13": "Official Fitzcarraldo page exposed an ISBN already used by another catalog record."}
    return records

def dataset(records: list[dict[str, object]]) -> dict[str, object]:
    urls = ["https://fitzcarraldoeditions.com/shop/"] + [f"https://fitzcarraldoeditions.com/shop/{c[0]}/" for c in CATEGORIES]
    return {
        "provider": PROVIDER,
        "retrieved_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "license_note": RIGHTS,
        "provider_permissions": {
            "provider": PROVIDER,
            "source_urls": urls,
            "source_hosts": ["fitzcarraldoeditions.com"],
            "cover_hosts": ["fitzcarraldoeditions.com"],
            "permission_basis": RIGHTS,
            "cover_cache_policy": "cache_allowed",
            "excluded_content": ["raw_html", "jacket_copy_dumps", "author_bios", "user_reviews", "prices", "inventory", "cart_checkout_account", "book_preview_text"],
            "takedown_contact": "https://fitzcarraldoeditions.com/contact/",
            "not_legal_advice": "This provider source policy is an engineering provenance control and is not legal advice.",
        },
        "records": records,
    }


def unique_books(books: Iterable[ListedBook]) -> list[ListedBook]:
    result: dict[str, ListedBook] = {}
    for book in books:
        result.setdefault(book.url, book)
    return list(result.values())


def main() -> int:
    listed = []
    for category in CATEGORIES:
        listed.extend(listing_books(*category))
        time.sleep(0.1)
    records: list[dict[str, object]] = []
    for index, book in enumerate(unique_books(listed), 1):
        meta = detail_metadata(book)
        if not meta.get("cover") or not meta.get("description"):
            print(f"missing required cover/description for {book.url}", file=sys.stderr)
            return 1
        records.append(record(book, meta, "paperback", None))
        if meta.get("ebook_isbn"):
            records.append(record(book, meta, "ebook", str(meta["ebook_isbn"])))
        if index % 25 == 0:
            print(f"fitzcarraldo {index} books / {len(records)} records", file=sys.stderr)
        time.sleep(0.05)
    records = remove_duplicate_isbns(records)
    OUT.write_text(json.dumps(dataset(records), indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {OUT} with {len(records)} records from {len(unique_books(listed))} books")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
