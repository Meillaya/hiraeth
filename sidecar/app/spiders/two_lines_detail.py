"""Two Lines Press detail-page parser for bounded enrichment."""

import re
from dataclasses import dataclass
from html import unescape
from typing import Final


@dataclass(frozen=True, slots=True)
class TwoLinesDetail:
    contributors: list[dict[str, str]]
    isbn_13: str | None
    published_on: str | None
    cover_url: str | None
    description: str | None


_ISBN13_PATTERN: Final = re.compile(r"(?<!\d)(97[89](?:[\s-]?\d){10})(?!\d)")
_TAG_PATTERN: Final = re.compile(r"<[^>]+>")
_SCRIPT_STYLE_PATTERN: Final = re.compile(r"<(script|style)\b[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
_TRANSLATOR_PATTERN: Final = re.compile(
    r"\btranslated(?:\s+from\s+[A-Za-z ,;-]+)?\s+by\s+(.+?)(?=\s+(?:ISBN|Publication Date)\b|$)",
    re.IGNORECASE,
)
_AUTHOR_PATTERN: Final = re.compile(r"(?:^|\s\|\s)By\s+(.+?)(?=\s+Translated\b|\s+ISBN\b|\s+Publication Date\b|$)")
_ROLE_BLOCK_PATTERN: Final = re.compile(
    r"<div\b[^>]*class=[\"'][^\"']*text-lg[^\"']*[\"'][^>]*>\s*(by|introduced by|translated by)\s*(?:from\s+[A-Za-z ]+)?\s*([^<]+?)\s*</div>",
    re.IGNORECASE,
)
_PUBLICATION_DATE_PATTERN: Final = re.compile(
    r"Publication Date:\s*(?:(\d{4}-\d{2}-\d{2})|([A-Z][a-z]+)\s+(\d{1,2}),\s+(\d{4}))",
    re.IGNORECASE,
)
_COVER_PATTERN: Final = re.compile(
    r"<img\b(?=[^>]*class=[\"'][^\"']*wp-post-image[^\"']*[\"'])[^>]*(?:data-src|src)=[\"']([^\"']+)[\"']",
    re.IGNORECASE,
)
_DESCRIPTION_PATTERN: Final = re.compile(
    r"<div\b[^>]*class=[\"'][^\"']*block--core-paragraph[^\"']*[\"'][^>]*>(.*?)</div>|<div\b[^>]*class=[\"'][^\"']*woocommerce-product-details__short-description[^\"']*[\"'][^>]*>(.*?)</div>",
    re.IGNORECASE | re.DOTALL,
)
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


def parse_two_lines_detail(html: str) -> TwoLinesDetail:
    """Extract bounded bibliographic enrichment from a Two Lines detail page."""
    inert_html = _SCRIPT_STYLE_PATTERN.sub(" ", html)
    text = _html_to_text(inert_html)
    return TwoLinesDetail(
        contributors=_contributors(text, inert_html),
        isbn_13=_isbn_from_text(text),
        published_on=_publication_date(text),
        cover_url=_cover_url(inert_html),
        description=_description(inert_html),
    )


def _html_to_text(html: str) -> str:
    text = _TAG_PATTERN.sub(" ", html)
    return re.sub(r"\s+", " ", unescape(text)).strip()


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


def _publication_date(text: str) -> str | None:
    match = _PUBLICATION_DATE_PATTERN.search(text)
    if not match:
        return None
    if match.group(1):
        return match.group(1)
    month = _MONTHS.get(match.group(2).lower())
    return f"{match.group(4)}-{month}-{int(match.group(3)):02d}" if month else None


def _contributors(text: str, html: str) -> list[dict[str, str]]:
    contributors: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()

    for match in _ROLE_BLOCK_PATTERN.finditer(html):
        role = _role_name(match.group(1))
        name = _clean_name(match.group(2))
        if name and (name, role) not in seen:
            contributors.append({"name": name, "role": role})
            seen.add((name, role))

    author_match = _AUTHOR_PATTERN.search(text)
    if author_match:
        name = _clean_name(author_match.group(1))
        if name and (name, "author") not in seen:
            contributors.append({"name": name, "role": "author"})
            seen.add((name, "author"))

    translator_match = _TRANSLATOR_PATTERN.search(text)
    if translator_match:
        name = _clean_name(translator_match.group(1))
        if name and (name, "translator") not in seen:
            contributors.append({"name": name, "role": "translator"})

    return contributors


def _role_name(value: str) -> str:
    normalized = value.lower()
    if normalized.startswith("translated"):
        return "translator"
    if normalized.startswith("introduced"):
        return "editor"
    return "author"


def _clean_name(value: str) -> str:
    candidate = re.split(r",|\.\s+|\$|Additional Info", value, maxsplit=1)[0]
    return re.sub(r"\s+", " ", candidate).strip(" .;,-")


def _cover_url(html: str) -> str | None:
    for match in _COVER_PATTERN.finditer(html):
        url = unescape(match.group(1).strip())
        if url.startswith("https://"):
            return url
    return None


def _description(html: str) -> str | None:
    match = _DESCRIPTION_PATTERN.search(html)
    if not match:
        return None
    raw = next((group for group in match.groups() if group), None)
    description = _html_to_text(raw or "")
    return description if description else None
