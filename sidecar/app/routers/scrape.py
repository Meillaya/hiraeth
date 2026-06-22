import importlib
import re
from typing import Any, Final, Protocol
from urllib.parse import urlparse

import anyio
from fastapi import APIRouter, HTTPException

from app.models import (
    DetailScrapeRequest,
    DetailScrapeResponse,
    ScrapeRequest,
    ScrapeResponse,
)
from app.spiders.deep_vellum_stealthy import (
    DeepVellumStealthySpider,
    ResponseTooLargeError,
    StealthyFetcher,
    _response_text,
)

router = APIRouter(prefix="/scrape", tags=["scrape"])


class CatalogSpider(Protocol):
    def to_json(self) -> list[dict[str, Any]]:
        """Return extracted catalog records."""
        ...


class CatalogSpiderFactory(Protocol):
    def __call__(self, *, config: dict[str, Any]) -> CatalogSpider:
        """Create a configured spider."""
        ...


def _load_spider_factory(module_name: str, class_name: str) -> CatalogSpiderFactory:
    module = importlib.import_module(module_name)
    return getattr(module, class_name)


DeepVellumSpider = _load_spider_factory(
    "app.spiders.deep_vellum_spider",
    "DeepVellumSpider",
)
GenericBookSpider = _load_spider_factory(
    "app.spiders.generic_book_spider",
    "GenericBookSpider",
)

_DEEP_VELLUM_PROVIDERS = {"deep_vellum", "deep_vellum_official_store"}
_FORBIDDEN_DETAIL_SEGMENTS: Final = {"account", "cart", "checkout"}
_DEEP_VELLUM_PRODUCT_PATH: Final = re.compile(r"^/products/([a-z0-9][a-z0-9-]*)$")


def _uses_deep_vellum_stealthy(request: ScrapeRequest) -> bool:
    if request.provider not in _DEEP_VELLUM_PROVIDERS:
        return False
    if request.config.get("scraper") == "spider":
        return False
    return request.config.get("use_stealthy_scraper", True) is not False


def _ensure_deep_vellum_detail_request(request: DetailScrapeRequest) -> None:
    if request.vendor not in _DEEP_VELLUM_PROVIDERS:
        raise HTTPException(status_code=422, detail="Unsupported detail vendor")

    parsed = urlparse(request.url)
    allowed_host = DeepVellumStealthySpider.base_url.removeprefix("https://")
    if parsed.scheme != "https" or parsed.netloc != allowed_host:
        raise HTTPException(status_code=422, detail="Unsupported detail URL host")
    if parsed.query or parsed.fragment:
        raise HTTPException(
            status_code=422,
            detail="Detail URL must not include query or fragment",
        )

    path_match = _DEEP_VELLUM_PRODUCT_PATH.fullmatch(parsed.path)
    if not path_match or path_match.group(1) in _FORBIDDEN_DETAIL_SEGMENTS:
        raise HTTPException(
            status_code=422,
            detail="Detail URL must target a Deep Vellum product",
        )


@router.post("/")
async def scrape_catalog(request: ScrapeRequest) -> ScrapeResponse:
    """Run a Scrapling spider to extract structured book metadata.

    The request config drives spider behaviour:
    - start_urls: list of URLs to crawl
    - selectors: CSS/XPath selectors for title, author, publisher, isbn, cover,
      description, publication_date, item
    - use_stealthy_fetcher: bool — use StealthyFetcher for dynamic pages
    - download_delay: float — seconds between requests
    - concurrent_requests: int — max parallel requests
    - max_blocked_retries: int — retry count for blocked responses
    """
    config = {
        **request.config,
        "provider": request.provider,
    }
    try:
        if _uses_deep_vellum_stealthy(request):
            records = await DeepVellumStealthySpider().scrape_catalog(config)
        else:
            spider_class = (
                DeepVellumSpider
                if request.provider in _DEEP_VELLUM_PROVIDERS
                else GenericBookSpider
            )
            spider = spider_class(config=config)
            records = await anyio.to_thread.run_sync(spider.to_json)

        return ScrapeResponse(
            provider=request.provider,
            status="success",
            records=records,
        )
    except Exception as e:
        return ScrapeResponse(
            provider=request.provider,
            status=f"error: {str(e)}",
            records=[],
        )


@router.post("/detail")
async def scrape_detail(request: DetailScrapeRequest) -> DetailScrapeResponse:
    """Fetch and parse a single allowlisted Deep Vellum product detail page."""
    _ensure_deep_vellum_detail_request(request)

    spider = DeepVellumStealthySpider()
    response = await StealthyFetcher.fetch_async(request.url, **spider.fetch_options)
    try:
        detail_text = _response_text(response, request.max_bytes)
    except ResponseTooLargeError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    detail = spider._parse_detail(detail_text)
    description = detail.description

    return DetailScrapeResponse(
        vendor=request.vendor,
        source_uri=request.url,
        contributors=spider._extract_contributors(description),
        isbn_13=spider._extract_isbn(description),
        published_on=spider._extract_publication_date(description),
        cover={
            "source_url": detail.cover_url,
            "rights_basis": "local_cache_permitted",
            "attribution_text": f"Cover via {request.vendor}",
        },
        description=description,
    )
