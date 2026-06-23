import ipaddress
import re
from dataclasses import dataclass
from html import unescape
from typing import Any, Final
from urllib.parse import urlparse

import anyio
import httpx

_TAG_PATTERN: Final = re.compile(r"<[^>]+>")
_PARAGRAPH_PATTERN: Final = re.compile(
    r"<p\b[^>]*>(.*?)</p>", re.IGNORECASE | re.DOTALL
)
_HEADING_PATTERN: Final = re.compile(
    r"<h2\b[^>]*>(.*?)</h2>", re.IGNORECASE | re.DOTALL
)
_ISBN13_PATTERN: Final = re.compile(r"(?<!\d)(97[89](?:[\s-]?\d){10})(?!\d)")
_MONTHS: Final = {
    "january": "01",
    "february": "02",
    "march": "03",
    "april": "04",
    "may": "05",
    "june": "06",
    "july": "07",
    "august": "08",
    "september": "09",
    "october": "10",
    "november": "11",
    "december": "12",
}
_HEADERS: Final = {"user-agent": "Mozilla/5.0 HiraethSidecar/1.0"}
_FORBIDDEN_DETAIL_SEGMENTS: Final = ("/cart", "/account", "/checkout", "/my-account")
_DEFAULT_DETAIL_PATH_PREFIXES: Final = ("/book/",)


@dataclass(frozen=True, slots=True)
class ImprintTerm:
    id: int
    slug: str
    name: str


@dataclass(frozen=True, slots=True)
class DetailMetadata:
    contributors: list[dict[str, str]]
    isbn_13: str | None
    published_on: str | None
    fmt: str | None
    page_count: int | None


def _build_field_sources(provider: str, source_uri: str) -> dict[str, Any]:
    basis = "Operator-authorized public catalog refresh from official publisher pages/APIs; factual bibliographic metadata, official product descriptions, official cover URLs, purchase links, and source provenance preserved for each field."
    return {
        "title": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "contributors": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "publisher": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "format": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "published_on": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "isbn_13": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "cover": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "description": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "storefront_url": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "subjects": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
        "page_count": {
            "provider": provider,
            "source_uri": source_uri,
            "source_type": "publisher_dataset",
            "rights_basis": basis,
        },
    }


def _html_to_text(raw_html: str | None) -> str:
    text = _TAG_PATTERN.sub(" ", raw_html or "")
    return re.sub(r"\s+", " ", unescape(text)).strip()


def _valid_isbn13(value: str) -> bool:
    digits = re.sub(r"\D", "", value)
    if len(digits) != 13 or not digits.startswith(("978", "979")):
        return False
    checksum = sum(
        (1 if index % 2 == 0 else 3) * int(digit)
        for index, digit in enumerate(digits[:12])
    )
    return (10 - checksum % 10) % 10 == int(digits[-1])


def _isbn_from_text(text: str | None) -> str | None:
    for match in _ISBN13_PATTERN.finditer(text or ""):
        candidate = re.sub(r"\D", "", match.group(1))
        if _valid_isbn13(candidate):
            return candidate
    return None


def _isbn_from_meta(meta: list[dict[str, Any]]) -> str | None:
    for item in meta:
        key = str(item.get("key") or "").lower()
        value = str(item.get("value") or "")
        if "isbn" not in key:
            continue
        isbn = _isbn_from_text(value)
        if isbn:
            return isbn
        digits = re.sub(r"\D", "", value)
        if len(digits) == 13 and digits.startswith(("978", "979")):
            return digits
    return None


def _format_from_text(text: str) -> str:
    lowered = text.lower()
    if "ebook" in lowered or "e-book" in lowered or "digital" in lowered:
        return "ebook"
    if "hardcover" in lowered or "hardback" in lowered or "cloth" in lowered:
        return "hardcover"
    return "paperback"


def _format_from_tags(tags: list[dict[str, Any]]) -> str:
    labels: list[str] = []
    for tag in tags:
        if isinstance(tag, dict):
            labels.append(str(tag.get("name") or ""))
        else:
            labels.append(str(tag))
    return _format_from_text(" ".join(labels))


def _post_title(post: dict[str, Any]) -> str:
    title_field = post.get("title")
    return _html_to_text(
        title_field.get("rendered", "")
        if isinstance(title_field, dict)
        else str(title_field or "")
    )


def _date_from_text(text: str) -> str | None:
    match = re.search(
        r"Published\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Z][a-z]+)\s+(\d{4})", text
    )
    if match:
        month = _MONTHS.get(match.group(2).lower())
        return f"{match.group(3)}-{month}-{int(match.group(1)):02d}" if month else None

    iso_match = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", text)
    if iso_match:
        return iso_match.group(1)
    return None


def _description_from_content(content: str) -> str | None:
    paragraphs: list[str] = []
    for match in _PARAGRAPH_PATTERN.finditer(content):
        paragraph = _html_to_text(match.group(1))
        if not paragraph:
            continue
        if paragraph.startswith(('"', "“", "‘")):
            break
        paragraphs.append(paragraph)
    if not paragraphs:
        text = _html_to_text(content)
        return text or None
    return " ".join(paragraphs)


def _cover_url(post: dict[str, Any], endpoint: str) -> str:
    embedded = post.get("_embedded", {})
    media = embedded.get("wp:featuredmedia", []) if isinstance(embedded, dict) else []
    if not media:
        featured_media = post.get("featured_media", 0)
        return (
            f"{endpoint}/wp-json/wp/v2/media/{featured_media}" if featured_media else ""
        )

    first = media[0]
    if not isinstance(first, dict):
        return ""

    details = first.get("media_details", {})
    sizes = details.get("sizes", {}) if isinstance(details, dict) else {}
    candidates: list[tuple[int, str]] = []
    for size in sizes.values():
        if not isinstance(size, dict):
            continue
        source_url = str(size.get("source_url") or "")
        width = int(size.get("width") or 0)
        height = int(size.get("height") or 0)
        if source_url.startswith("https://"):
            candidates.append((width * height, source_url))
    source_url = str(first.get("source_url") or "")
    if source_url.startswith("https://"):
        candidates.append((0, source_url))
    return max(candidates, default=(0, ""), key=lambda candidate: candidate[0])[1]


def _imprint_terms(raw_terms: list[dict[str, Any]]) -> dict[int, ImprintTerm]:
    terms: dict[int, ImprintTerm] = {}
    for item in raw_terms:
        term_id = item.get("id")
        slug = str(item.get("slug") or "")
        name = str(item.get("name") or "")
        if isinstance(term_id, int) and slug and name:
            terms[term_id] = ImprintTerm(id=term_id, slug=slug, name=name)
    return terms


def _post_imprints(
    post: dict[str, Any], terms: dict[int, ImprintTerm]
) -> list[ImprintTerm]:
    return [
        terms[term_id]
        for term_id in post.get("imprint", [])
        if isinstance(term_id, int) and term_id in terms
    ]


def _safe_source_uri(
    post: dict[str, Any],
    endpoint: str,
    source_hosts: set[str],
    detail_path_prefixes: tuple[str, ...],
) -> str:
    link = str(post.get("link") or "")
    return (
        link
        if _allowed_detail_url(link, source_hosts, detail_path_prefixes)
        else f"{endpoint}/?p={post.get('id', '')}"
    )


def _allowed_detail_url(
    source_uri: str, source_hosts: set[str], detail_path_prefixes: tuple[str, ...]
) -> bool:
    parsed = urlparse(source_uri)
    if parsed.scheme != "https" or not parsed.hostname:
        return False
    if parsed.username or parsed.password or parsed.hostname not in source_hosts:
        return False
    if parsed.query or parsed.fragment:
        return False
    if any(parsed.path.startswith(segment) for segment in _FORBIDDEN_DETAIL_SEGMENTS):
        return False
    if detail_path_prefixes and not parsed.path.startswith(detail_path_prefixes):
        return False
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        return True
    return not (
        address.is_private
        or address.is_loopback
        or address.is_link_local
        or address.is_unspecified
    )


def _detail_path_prefixes(api_config: dict[str, Any]) -> tuple[str, ...]:
    raw_prefixes = (
        api_config.get("detail_path_prefixes") or _DEFAULT_DETAIL_PATH_PREFIXES
    )
    prefixes = [str(prefix) for prefix in raw_prefixes if str(prefix).startswith("/")]
    return tuple(prefixes)


def _total_pages(headers: httpx.Headers | dict[str, str]) -> int:
    try:
        return max(int(headers.get("X-WP-TotalPages", "1")), 1)
    except (TypeError, ValueError):
        return 1


def _included_post(
    post: dict[str, Any],
    terms: dict[int, ImprintTerm],
    include: set[str],
    exclude: set[str],
) -> bool:
    imprints = _post_imprints(post, terms)
    slugs = {term.slug for term in imprints}
    if slugs & exclude:
        return False
    return not include or bool(slugs & include)


def _normalized_heading(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().casefold()


def _contributor_headings(html: str, title: str | None = None) -> list[str]:
    headings = [
        _html_to_text(match.group(1)).strip()
        for match in _HEADING_PATTERN.finditer(html)
    ]
    title_key = _normalized_heading(title or "")
    filtered = [
        heading
        for heading in headings
        if heading
        and not heading.lower().startswith("follow ")
        and _normalized_heading(heading) != title_key
    ]
    contributors = filtered
    if len(contributors) >= 2 and _looks_like_subtitle(contributors[0]):
        return contributors[1:]
    return contributors


def _looks_like_subtitle(text: str) -> bool:
    lowered = text.lower()
    if lowered.startswith(("translated by ", "illustrated by ", "edited by ")):
        return False
    return len(text) > 34 and not re.fullmatch(
        r"[A-Z][A-Za-zÀ-ÖØ-öø-ÿ'’.-]+(?:\s+[A-Z][A-Za-zÀ-ÖØ-öø-ÿ'’.-]+){0,4}", text
    )


def _contributors_from_detail(
    html: str, title: str | None = None
) -> list[dict[str, str]]:
    contributors: list[dict[str, str]] = []
    for text in _contributor_headings(html, title):
        lowered = text.lower()
        if lowered.startswith("translated by "):
            contributors.append({"name": text[14:].strip(), "role": "translator"})
        elif lowered.startswith("illustrated by "):
            contributors.append({"name": text[15:].strip(), "role": "illustrator"})
        elif lowered.startswith("edited by "):
            contributors.append({"name": text[10:].strip(), "role": "editor"})
        elif " by " not in lowered and lowered not in {"praise", "about"}:
            contributors.append({"name": text, "role": "author"})
    return contributors[:4]


def _contributors_from_possessive_title(
    text: str, title: str | None
) -> list[dict[str, str]]:
    if not title:
        return []

    normalized_text = text.replace("’", "'")
    title_pattern = re.escape(title.replace("’", "'"))
    pattern = rf"\b([A-Z][A-Za-zÀ-ÖØ-öø-ÿ'.-]+(?:\s+[A-Z][A-Za-zÀ-ÖØ-öø-ÿ'.-]+){{0,3}})'s\s+{title_pattern}\b"
    match = re.search(pattern, normalized_text)
    return [{"name": match.group(1), "role": "author"}] if match else []


def _detail_metadata(html: str, title: str | None = None) -> DetailMetadata:
    text = _html_to_text(html)
    page_match = re.search(r"Pages\s+(\d{1,5})\b", text)
    contributors = _contributors_from_detail(
        html, title
    ) or _contributors_from_possessive_title(text, title)
    return DetailMetadata(
        contributors=contributors,
        isbn_13=_isbn_from_text(text),
        published_on=_date_from_text(text),
        fmt=_format_from_text(text),
        page_count=int(page_match.group(1)) if page_match else None,
    )


def _post_to_record(
    post: dict[str, Any],
    provider: str,
    endpoint: str,
    publisher_name: str | None,
    terms: dict[int, ImprintTerm] | None = None,
    detail: DetailMetadata | None = None,
    source_hosts: set[str] | None = None,
    detail_path_prefixes: tuple[str, ...] = _DEFAULT_DETAIL_PATH_PREFIXES,
) -> dict[str, Any]:
    source_uri = _safe_source_uri(
        post,
        endpoint,
        source_hosts or {urlparse(endpoint).hostname or ""},
        detail_path_prefixes,
    )
    title = _post_title(post)
    content_field = post.get("content")
    content = (
        content_field.get("rendered", "")
        if isinstance(content_field, dict)
        else str(content_field or "")
    )
    excerpt_field = post.get("excerpt")
    excerpt = (
        excerpt_field.get("rendered", "")
        if isinstance(excerpt_field, dict)
        else str(excerpt_field or "")
    )
    description = _description_from_content(excerpt or content)
    published_on = (detail.published_on if detail else None) or (
        str(post.get("date") or "")[:10] or None
    )
    isbn = (
        (detail.isbn_13 if detail else None)
        or _isbn_from_meta(post.get("meta", []))
        or _isbn_from_text(content)
    )
    fmt = (detail.fmt if detail else None) or _format_from_tags(post.get("tags", []))
    imprints = _post_imprints(post, terms or {})
    imprint = imprints[0].name if imprints else None
    contributors = detail.contributors if detail else []
    cover_url = _cover_url(post, endpoint)
    tags = [term.name for term in imprints]
    if not tags:
        raw_tags = post.get("tags", [])
        tags = [str(tag.get("name") or tag) for tag in raw_tags]
    displayed_fields = ["title", "publisher", "format", "storefront_url"]
    displayed_fields += [
        field
        for field, value in (
            ("contributors", contributors),
            ("published_on", published_on),
            ("isbn_13", isbn),
            ("cover", cover_url),
            ("description", description),
            ("subjects", tags),
        )
        if value
    ]

    record: dict[str, Any] = {
        "provider": provider,
        "source_uri": source_uri,
        "source_product_id": str(post.get("id", "")),
        "source_sku": isbn or "",
        "publisher": publisher_name or provider,
        "imprint": imprint,
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
            "page_count": detail.page_count if detail else None,
        },
        "contributors": contributors,
        "displayed_fields": displayed_fields,
        "curation": {
            "status": "approved",
            "notes": "Operator-authorized full-catalog refresh from public source; generated deterministically with field provenance.",
        },
        "storefront_url": source_uri,
        "field_sources": _build_field_sources(provider, source_uri),
        "description": description,
    }
    if cover_url:
        record["cover"] = {
            "source_url": cover_url,
            "provider": provider,
            "rights_basis": "local_cache_permitted",
            "attribution_text": "Cover via official source",
            "attribution_url": source_uri,
            "cache_policy": "cache_allowed",
        }
    else:
        record["no_cover_reason"] = "not present in source record"
    if not isbn:
        record["missing_fields"] = {"isbn_13": "not present in source record"}
    return record


async def _fetch_taxonomy(
    client: httpx.AsyncClient, endpoint: str, taxonomy: str, max_bytes: int
) -> dict[int, ImprintTerm]:
    response = await client.get(
        f"{endpoint}/wp-json/wp/v2/{taxonomy}?per_page=100", headers=_HEADERS
    )
    response.raise_for_status()
    if len(response.content) > max_bytes:
        return {}
    body = response.json()
    return _imprint_terms(body if isinstance(body, list) else [])


async def _fetch_detail(
    client: httpx.AsyncClient, source_uri: str, max_bytes: int, title: str | None = None
) -> DetailMetadata | None:
    response = await client.get(source_uri, headers=_HEADERS)
    response.raise_for_status()
    if len(response.content) > max_bytes:
        return None
    return _detail_metadata(response.text, title)


async def fetch(config: dict[str, Any]) -> list[dict[str, Any]]:
    endpoint = config["api"]["endpoint"].rstrip("/")
    provider = config.get("provider", "unknown")
    publisher_name = config.get("publisher_name")
    api_config = config["api"]
    post_type = str(api_config.get("post_type") or "posts")
    taxonomy = str(api_config.get("taxonomy") or "")
    include = {str(slug) for slug in api_config.get("include_imprints") or []}
    exclude = {str(slug) for slug in api_config.get("exclude_imprints") or []}
    fetch_detail_pages = api_config.get("fetch_detail_pages", False) is True
    rate_limit = config.get("rate_limit", {})
    min_delay_ms = rate_limit.get("min_delay_ms", 0)
    max_bytes = rate_limit.get("max_bytes", 10 * 1024 * 1024)
    source_hosts = {str(host) for host in config.get("source_hosts", [])}
    if not source_hosts:
        source_hosts = {urlparse(endpoint).hostname or ""}
    detail_path_prefixes = _detail_path_prefixes(api_config)

    records: list[dict[str, Any]] = []
    page = 1

    async with httpx.AsyncClient() as client:
        terms = (
            await _fetch_taxonomy(client, endpoint, taxonomy, max_bytes)
            if taxonomy
            else {}
        )
        while True:
            url = f"{endpoint}/wp-json/wp/v2/{post_type}?per_page=100&page={page}&_embed=1"
            response = await client.get(url, headers=_HEADERS)
            response.raise_for_status()
            if len(response.content) > max_bytes:
                break
            posts = response.json()
            if not isinstance(posts, list) or not posts:
                break
            for post in posts:
                if terms and not _included_post(post, terms, include, exclude):
                    continue
                raw_source_uri = str(post.get("link") or "")
                detail_source_uri = (
                    raw_source_uri
                    if _allowed_detail_url(
                        raw_source_uri, source_hosts, detail_path_prefixes
                    )
                    else ""
                )
                detail = None
                if fetch_detail_pages and detail_source_uri:
                    detail = await _fetch_detail(
                        client, detail_source_uri, max_bytes, _post_title(post)
                    )
                    if min_delay_ms:
                        await anyio.sleep(min_delay_ms / 1000)
                records.append(
                    _post_to_record(
                        post,
                        provider,
                        endpoint,
                        publisher_name,
                        terms,
                        detail,
                        source_hosts,
                        detail_path_prefixes,
                    )
                )
            total_pages = _total_pages(response.headers)
            if page >= total_pages:
                break
            page += 1
            if min_delay_ms:
                await anyio.sleep(min_delay_ms / 1000)

    return records
