import re
from dataclasses import dataclass
from html import unescape
from typing import Any, Final
from urllib.parse import urljoin, urlparse

from app.spiders.deep_vellum_stealthy import StealthyFetcher, _response_text


class AstraHouseCatalogUrlNotAllowedError(ValueError):
    def __init__(self) -> None:
        super().__init__("Astra House catalog URL is not allowlisted")


@dataclass(frozen=True, slots=True)
class FormatOption:
    source_uri: str
    format: str
    isbn_13: str | None


@dataclass(frozen=True, slots=True)
class ProductDetail:
    title: str
    author: str | None
    isbn_13: str | None
    published_on: str | None
    cover_url: str | None
    description: str | None
    editorial_praise: list[dict[str, str]]
    formats: list[FormatOption]


ASTRA_HOUSE_PROVIDER: Final = "astra_house_official_store"
ASTRA_HOUSE_NAME: Final = "Astra House"
ASTRA_HOUSE_CATALOG_URL: Final = "https://astrapublishinghouse.com/imprints/astra-house/"
_PRODUCT_PATH: Final = re.compile(r"^/product/([a-z0-9][a-z0-9-]*)/?$")
_FORBIDDEN_SEGMENTS: Final = {"account", "cart", "checkout"}
_LINK_PATTERN: Final = re.compile(
    r"(?:<a\b[^>]*href|<[^>]+\bdata-permalink)=[\"']([^\"']+)[\"'][^>]*>",
    re.IGNORECASE,
)
_TAG_PATTERN: Final = re.compile(r"<[^>]+>")
_SCRIPT_STYLE_PATTERN: Final = re.compile(r"<(script|style)\b[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
_ISBN13_PATTERN: Final = re.compile(r"(?<!\d)(97[89](?:[\s-]?\d){10})(?!\d)")
_TITLE_PATTERN: Final = re.compile(
    r"<h2\b[^>]*>\s*<a\b[^>]*>(.*?)</a>\s*</h2>|<h1\b[^>]*class=[\"'][^\"']*product_title[^\"']*[\"'][^>]*>(.*?)</h1>",
    re.IGNORECASE | re.DOTALL,
)
_AUTHOR_PATTERN: Final = re.compile(
    r"<li>\s*Author:\s*<a\b[^>]*>(.*?)</a>\s*</li>|<p\b[^>]*class=[\"'][^\"']*author[^\"']*[\"'][^>]*>(.*?)</p>",
    re.IGNORECASE | re.DOTALL,
)
_DATE_PATTERN: Final = re.compile(
    r"<span>\s*Published:\s*</span>\s*(\d{2})/(\d{2})/(\d{4})|Publication Date:\s*(\d{4}-\d{2}-\d{2})",
    re.IGNORECASE,
)
_COVER_PATTERN: Final = re.compile(
    r"(?:src|content)=[\"'](https?://images\.penguinrandomhouse\.com/[^\"']+)[\"']|"
    + r"[\"'](?:thumbnailUrl|image)[\"']\s*:\s*[\"'](https?:\\?/\\?/images\.penguinrandomhouse\.com\\?/[^\"']+)[\"']",
    re.IGNORECASE,
)
_ABOUT_PATTERN: Final = re.compile(
    r"<div\b[^>]*class=[\"'][^\"']*book-about-body[^\"']*[\"'][^>]*>(.*?)<div\b[^>]*class=[\"'][^\"']*bookpage-detailslist",
    re.IGNORECASE | re.DOTALL,
)
_DESCRIPTION_PATTERN: Final = re.compile(r"<div\b[^>]*class=[\"'][^\"']*description[^\"']*[\"'][^>]*>(.*?)</div>", re.IGNORECASE | re.DOTALL)
_PRAISE_SECTION_PATTERN: Final = re.compile(
    r"<div\b[^>]*class=[\"'][^\"']*book-accordion-section[^\"']*[\"'][^>]*data-accordion=[\"']praise[\"'][^>]*>.*?"
    r"<div\b[^>]*class=[\"'][^\"']*book-accordion-body[^\"']*[\"'][^>]*>(.*?)</div>\s*</div>",
    re.IGNORECASE | re.DOTALL,
)
_PARAGRAPH_PATTERN: Final = re.compile(r"<p\b[^>]*>(.*?)</p>", re.IGNORECASE | re.DOTALL)
_BREAK_PATTERN: Final = re.compile(r"<br\s*/?>", re.IGNORECASE)
_OPTION_PATTERN: Final = re.compile(r"<option\b([^>]*)>(.*?)</option>", re.IGNORECASE | re.DOTALL)
_DATA_URL_PATTERN: Final = re.compile(r"\bdata-url=[\"']([^\"']+)[\"']", re.IGNORECASE)
_SELECTED_PATTERN: Final = re.compile(r"\bselected(?:=[\"']selected[\"'])?\b", re.IGNORECASE)


class AstraHouseSpider:
    fetch_options: Final = {
        "headless": True,
        "network_idle": True,
        "disable_resources": True,
        "humanize": True,
        "google_search": False,
        "useragent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/125 Safari/537.36",
    }

    async def scrape_catalog(self, config: dict[str, Any]) -> list[dict[str, Any]]:
        provider = str(config.get("provider") or ASTRA_HOUSE_PROVIDER)
        catalog_url = self.catalog_url(config)
        max_bytes = _max_bytes(config)
        listing_response = await StealthyFetcher.fetch_async(catalog_url, **self.fetch_options)
        listing = _response_text(listing_response, max_bytes)
        product_urls = _product_urls(listing, catalog_url)
        records: list[dict[str, Any]] = []
        seen_urls: set[str] = set()

        for product_url in product_urls:
            if product_url in seen_urls:
                continue
            response = await StealthyFetcher.fetch_async(product_url, **self.fetch_options)
            detail = parse_astra_house_detail(_response_text(response, max_bytes), product_url)
            for option in detail.formats:
                seen_urls.add(option.source_uri)
            records.append(_record(provider, detail, detail.formats[0]))

        return records

    @staticmethod
    def catalog_url(config: dict[str, Any]) -> str:
        start_urls = config.get("start_urls")
        if isinstance(start_urls, list) and start_urls:
            first = start_urls[0]
            if isinstance(first, str):
                return _validate_catalog_url(first)
        return ASTRA_HOUSE_CATALOG_URL


def _max_bytes(config: dict[str, Any]) -> int | None:
    rate_limit = config.get("rate_limit")
    if isinstance(rate_limit, dict):
        value = rate_limit.get("max_bytes")
        return value if isinstance(value, int) and value > 0 else None
    return None


def _validate_catalog_url(url: str) -> str:
    parsed = urlparse(url)
    if (
        parsed.scheme == "https"
        and parsed.netloc == "astrapublishinghouse.com"
        and parsed.path == "/imprints/astra-house/"
        and not parsed.query
        and not parsed.fragment
        and not parsed.username
        and not parsed.password
    ):
        return url
    raise AstraHouseCatalogUrlNotAllowedError()


def _product_urls(html: str, base_url: str) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for match in _LINK_PATTERN.finditer(html):
        url = urljoin(base_url, unescape(match.group(1).strip()))
        if _allowed_product_url(url) and url not in seen:
            urls.append(url)
            seen.add(url)
    return urls


def _allowed_product_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "astrapublishinghouse.com":
        return False
    if parsed.query or parsed.fragment or parsed.username or parsed.password:
        return False
    path_match = _PRODUCT_PATH.fullmatch(parsed.path)
    return bool(path_match and path_match.group(1) not in _FORBIDDEN_SEGMENTS)


def parse_astra_house_detail(html: str, source_uri: str) -> ProductDetail:
    inert_html = _SCRIPT_STYLE_PATTERN.sub(" ", html)
    text = _html_to_text(inert_html)
    title = _extract_html_text(_TITLE_PATTERN, inert_html) or _title_from_url(source_uri)
    isbn = _isbn_from_text(text) or _isbn_from_text(source_uri)
    cover_url = _cover_url(html)
    formats = _format_options(inert_html, source_uri, isbn)
    return ProductDetail(
        title=title,
        author=_author(inert_html),
        isbn_13=isbn,
        published_on=_publication_date(text),
        cover_url=cover_url,
        description=_description(inert_html),
        editorial_praise=_editorial_praise(inert_html, source_uri),
        formats=formats,
    )


def _format_options(html: str, source_uri: str, primary_isbn: str | None) -> list[FormatOption]:
    options = [FormatOption(source_uri=source_uri, format=_current_format(html), isbn_13=primary_isbn)]
    for match in _OPTION_PATTERN.finditer(html):
        attrs = match.group(1)
        data_url = _option_data_url(attrs)
        if not data_url:
            continue
        option_url = urljoin(source_uri, unescape(data_url.strip()))
        if not _allowed_product_url(option_url):
            continue
        label = _html_to_text(match.group(2))
        isbn = _isbn_from_text(option_url) or primary_isbn
        options.append(FormatOption(source_uri=option_url, format=_format_from_label(label), isbn_13=isbn))
    return _unique_options(options)


def _current_format(html: str) -> str:
    for match in _OPTION_PATTERN.finditer(html):
        if _SELECTED_PATTERN.search(match.group(1)):
            return _format_from_label(_html_to_text(match.group(2)))
    return "paperback"


def _option_data_url(attrs: str) -> str | None:
    match = _DATA_URL_PATTERN.search(attrs)
    return unescape(match.group(1)) if match else None


def _unique_options(options: list[FormatOption]) -> list[FormatOption]:
    unique: list[FormatOption] = []
    seen: set[str] = set()
    for option in options:
        if option.source_uri not in seen:
            unique.append(option)
            seen.add(option.source_uri)
    return unique


def _format_from_label(label: str) -> str:
    normalized = label.lower()
    if "ebook" in normalized or "e-book" in normalized or "digital" in normalized:
        return "ebook"
    if "hardcover" in normalized or "hardback" in normalized:
        return "hardcover"
    return "paperback"


def _html_to_text(html: str) -> str:
    text = _TAG_PATTERN.sub(" ", html)
    return re.sub(r"\s+", " ", unescape(text)).strip()


def _extract_html_text(pattern: re.Pattern[str], html: str) -> str | None:
    match = pattern.search(html)
    if not match:
        return None
    raw = next((group for group in match.groups() if group), None)
    return _html_to_text(raw) if raw else None


def _valid_isbn13(value: str) -> bool:
    if len(value) != 13 or not value.startswith(("978", "979")):
        return False
    checksum = sum((1 if index % 2 == 0 else 3) * int(digit) for index, digit in enumerate(value[:12]))
    return (10 - checksum % 10) % 10 == int(value[-1])


def _isbn_from_text(text: str) -> str | None:
    for match in _ISBN13_PATTERN.finditer(text):
        candidate = re.sub(r"\D", "", match.group(1))
        if _valid_isbn13(candidate):
            return candidate
    return None


def _title_from_url(url: str) -> str:
    slug = urlparse(url).path.strip("/").split("/")[-1]
    title = re.sub(r"-97[89]\d{10}$", "", slug)
    return " ".join(part.capitalize() for part in title.split("-") if part)


def _author(html: str) -> str | None:
    raw = _extract_html_text(_AUTHOR_PATTERN, html)
    if not raw:
        return None
    return re.sub(r"^by\s+", "", raw, flags=re.IGNORECASE).strip()


def _publication_date(text: str) -> str | None:
    match = _DATE_PATTERN.search(text)
    if not match:
        return None
    if match.group(4):
        return match.group(4)
    month, day, year = match.group(1), match.group(2), match.group(3)
    return f"{year}-{month}-{day}"


def _cover_url(html: str) -> str | None:
    match = _COVER_PATTERN.search(html)
    if not match:
        return None
    raw = next((group for group in match.groups() if group), None)
    if not raw:
        return None
    url = unescape(raw.strip()).replace("\\/", "/")
    return url.replace("http://", "https://", 1)


def _description(html: str) -> str | None:
    raw = _extract_html_text(_ABOUT_PATTERN, html) or _extract_html_text(_DESCRIPTION_PATTERN, html)
    return raw if raw else None


def _editorial_praise(html: str, source_uri: str) -> list[dict[str, str]]:
    section_match = _PRAISE_SECTION_PATTERN.search(html)
    if not section_match:
        return []

    praise: list[dict[str, str]] = []
    for paragraph_match in _PARAGRAPH_PATTERN.finditer(section_match.group(1)):
        praise.extend(_praise_items(paragraph_match.group(1), source_uri))
    return praise


def _praise_items(html: str, source_uri: str) -> list[dict[str, str]]:
    items: list[dict[str, str]] = []
    quote_lines: list[str] = []
    for line in _html_lines(_BREAK_PATTERN.sub("\n", html)):
        if _source_line(line):
            item = _praise_item(" ".join(quote_lines), line, source_uri)
            if item:
                items.append(item)
            quote_lines = []
        else:
            quote_lines.append(line)

    if quote_lines:
        item = _praise_item(" ".join(quote_lines), "Publisher official page", source_uri)
        if item:
            items.append(item)

    return items


def _praise_item(quote: str, source: str, source_uri: str) -> dict[str, str] | None:
    if not source or source == "Publisher official page":
        quote, source = _split_praise_source(quote)
    quote = quote.strip().strip("\"“”")
    source = source.strip().lstrip("—–-").strip() or "Publisher official page"
    if not quote:
        return None

    return {"quote": quote, "source": source, "source_uri": source_uri}


def _html_lines(html: str) -> list[str]:
    text = _TAG_PATTERN.sub(" ", html)
    return [line for raw_line in unescape(text).splitlines() if (line := re.sub(r"\s+", " ", raw_line).strip())]


def _source_line(text: str) -> bool:
    return text.lstrip().startswith(("—", "–", "-"))


def _split_praise_source(text: str) -> tuple[str, str]:
    parts = re.split(r"\s+[—–]\s*", text, maxsplit=1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return text, "Publisher official page"


def _record(provider: str, detail: ProductDetail, option: FormatOption) -> dict[str, Any]:
    isbn = option.isbn_13 or detail.isbn_13
    cover_url = _cover_for_isbn(detail.cover_url, isbn)
    contributors = [{"name": detail.author, "role": "author"}] if detail.author else []
    record = {
        "provider": provider,
        "source_uri": option.source_uri,
        "source_product_id": isbn or option.source_uri.rstrip("/").split("/")[-1],
        "source_sku": isbn or "",
        "publisher": ASTRA_HOUSE_NAME,
        "imprint": ASTRA_HOUSE_NAME,
        "work": {"title": detail.title, "subtitle": None, "original_title": None, "publication_state": "published"},
        "edition": {"title": detail.title, "subtitle": None, "format": option.format, "published_on": detail.published_on, "isbn_13": isbn},
        "contributors": contributors,
        "displayed_fields": _displayed_fields(isbn, detail.published_on, cover_url, detail.description, detail.editorial_praise, contributors),
        "curation": {"status": "approved", "notes": "Operator-authorized Astra House imprint scrape with official product-page provenance."},
        "storefront_url": option.source_uri,
        "field_sources": _field_sources(provider, option.source_uri),
        "cover": {"source_url": cover_url, "provider": provider, "rights_basis": "local_cache_permitted", "attribution_text": "Cover via Astra House official source", "attribution_url": option.source_uri, "cache_policy": "cache_allowed"},
        "description": detail.description,
        "editorial_praise": detail.editorial_praise,
        "no_cover_reason": None if cover_url else "source_page_missing_cover",
    }
    return record


def _cover_for_isbn(cover_url: str | None, isbn: str | None) -> str | None:
    if cover_url and isbn and cover_url.startswith("https://images.penguinrandomhouse.com/"):
        return re.sub(r"97[89]\d{10}$", isbn, cover_url)
    return cover_url


def _displayed_fields(
    isbn: str | None,
    published_on: str | None,
    cover_url: str | None,
    description: str | None,
    editorial_praise: list[dict[str, str]],
    contributors: list[dict[str, str]],
) -> list[str]:
    optional_fields = (
        ("contributors", contributors),
        ("published_on", published_on),
        ("isbn_13", isbn),
        ("cover", cover_url),
        ("description", description),
        ("editorial_praise", editorial_praise),
    )
    return ["title", "publisher", "format", "storefront_url"] + [field for field, value in optional_fields if value]


def _field_sources(provider: str, source_uri: str) -> dict[str, Any]:
    basis = "Operator-authorized public catalog refresh from official publisher pages/APIs; factual bibliographic metadata, official product descriptions, official cover URLs, purchase links, and source provenance preserved for each field."
    return {
        field: {"provider": provider, "source_uri": source_uri, "source_type": "publisher_dataset", "rights_basis": basis}
        for field in (
            "title",
            "contributors",
            "publisher",
            "format",
            "published_on",
            "isbn_13",
            "cover",
            "description",
            "editorial_praise",
            "storefront_url",
        )
    }
