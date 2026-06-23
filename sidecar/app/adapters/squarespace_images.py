import html
import re
from typing import Any
from urllib.parse import urljoin, urlparse

_PRODUCT_BLOCK_RE = re.compile(
    r"<[^>]+data-item-id=[\"']([^\"']+)[\"'][^>]*>.*?(?=<[^>]+data-item-id=[\"']|</body|$)",
    re.IGNORECASE | re.DOTALL,
)
_IMAGE_ATTR_RE = re.compile(
    r"<img\b[^>]+(?:data-src|data-image|src)=[\"']([^\"']+)[\"']",
    re.IGNORECASE | re.DOTALL,
)


def absolute_url(endpoint: str, raw_url: str) -> str:
    return raw_url if raw_url.startswith(("http://", "https://")) else urljoin(endpoint, raw_url)


def usable_cover_url(url: Any) -> bool:
    if not url:
        return False

    raw_url = str(url)
    lower_url = raw_url.lower()
    if "no-image" in lower_url or "/static/book-cover/" in lower_url:
        return False

    parsed = urlparse(raw_url)
    if parsed.netloc == "static1.squarespace.com" and parsed.path.endswith("/"):
        return False

    return True


def listing_cover_urls(html_body: str, endpoint: str) -> dict[str, str]:
    cover_urls: dict[str, str] = {}

    for match in _PRODUCT_BLOCK_RE.finditer(html_body):
        item_id = html.unescape(match.group(1)).strip()
        image_match = _IMAGE_ATTR_RE.search(match.group(0))
        if not image_match:
            continue

        cover_url = absolute_url(endpoint, html.unescape(image_match.group(1)).strip())
        if usable_cover_url(cover_url):
            cover_urls[item_id] = cover_url

    return cover_urls
