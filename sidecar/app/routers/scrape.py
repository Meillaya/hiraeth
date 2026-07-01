import importlib
import re
from typing import Final, Protocol
from urllib.parse import ParseResult, urlparse

from anyio import to_thread
from fastapi import APIRouter

from app.models import (
    DetailScrapeRequest,
    DetailScrapeResponse,
    ERROR_RESPONSES,
    JsonObject,
    ScrapeRequest,
    ScrapeResponse,
    SidecarErrorCode,
    sidecar_http_error,
    sidecar_runtime_error,
)
from app.url_validation import validate_start_urls_against_source_hosts
from app.spiders.astra_house import (
    ASTRA_HOUSE_PROVIDER,
    AstraHouseCatalogUrlNotAllowedError,
    AstraHouseSpider,
)
from app.spiders.deep_vellum_stealthy import (
    CatalogUrlNotAllowedError,
    DeepVellumStealthySpider,
    ResponseTooLargeError,
    StealthyFetcher,
    _response_text,
)
from app.spiders.two_lines_detail import parse_two_lines_detail

router = APIRouter(prefix="/scrape", tags=["scrape"])


class CatalogSpider(Protocol):
    def to_json(self) -> list[JsonObject]:
        """Return extracted catalog records."""
        ...


class CatalogSpiderFactory(Protocol):
    def __call__(self, *, config: JsonObject) -> CatalogSpider:
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
_TWO_LINES_PROVIDERS = {"two_lines_press_official_store"}
_ASTRA_HOUSE_PROVIDERS = {ASTRA_HOUSE_PROVIDER}
_FORBIDDEN_DETAIL_SEGMENTS: Final = {"account", "cart", "checkout"}
_DEEP_VELLUM_PRODUCT_PATH: Final = re.compile(r"^/products/([a-z0-9][a-z0-9-]*)$")
_TWO_LINES_BOOK_PATH: Final = re.compile(
    r"^/shop/books/(?:[a-z0-9][a-z0-9-]*/)*([a-z0-9][a-z0-9-]*)/?$",
)


def _uses_deep_vellum_stealthy(request: ScrapeRequest) -> bool:
    if request.provider not in _DEEP_VELLUM_PROVIDERS:
        return False
    if request.config.get("scraper") == "spider":
        return False
    return request.config.get("use_stealthy_scraper", True) is not False


def _ensure_detail_request(request: DetailScrapeRequest) -> None:
    parsed = urlparse(request.url)
    if request.vendor in _DEEP_VELLUM_PROVIDERS:
        _ensure_deep_vellum_detail_url(parsed)
        return
    if request.vendor in _TWO_LINES_PROVIDERS:
        _ensure_two_lines_detail_url(parsed)
        return
    raise sidecar_http_error(
        422,
        SidecarErrorCode.INVALID_HOST,
        "Unsupported detail vendor",
    )


def _ensure_common_detail_url(parsed: ParseResult) -> None:
    if parsed.scheme != "https" or parsed.username or parsed.password:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Unsupported detail URL host",
        )
    if parsed.query or parsed.fragment:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Detail URL must not include query or fragment",
        )


def _ensure_deep_vellum_detail_url(parsed: ParseResult) -> None:
    _ensure_common_detail_url(parsed)
    allowed_host = DeepVellumStealthySpider.base_url.removeprefix("https://")
    if parsed.netloc != allowed_host:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Unsupported detail URL host",
        )

    path_match = _DEEP_VELLUM_PRODUCT_PATH.fullmatch(parsed.path)
    if not path_match or path_match.group(1) in _FORBIDDEN_DETAIL_SEGMENTS:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Detail URL must target a Deep Vellum product",
        )


def _ensure_two_lines_detail_url(parsed: ParseResult) -> None:
    _ensure_common_detail_url(parsed)
    if parsed.netloc != "www.twolinespress.com":
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Unsupported detail URL host",
        )

    path_match = _TWO_LINES_BOOK_PATH.fullmatch(parsed.path)
    segments = set(parsed.path.strip("/").split("/"))
    if not path_match or segments.intersection(_FORBIDDEN_DETAIL_SEGMENTS):
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Detail URL must target a Two Lines book",
        )


@router.post("/", responses=ERROR_RESPONSES)
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
        if request.provider in _DEEP_VELLUM_PROVIDERS:
            _ = DeepVellumStealthySpider.catalog_url(config)
        if request.provider in _ASTRA_HOUSE_PROVIDERS:
            _ = AstraHouseSpider.catalog_url(config)
        if (
            request.provider not in _DEEP_VELLUM_PROVIDERS
            and request.provider not in _ASTRA_HOUSE_PROVIDERS
        ):
            validate_start_urls_against_source_hosts(config)

        if _uses_deep_vellum_stealthy(request):
            records = await DeepVellumStealthySpider().scrape_catalog(config)
        elif request.provider in _ASTRA_HOUSE_PROVIDERS:
            records = await AstraHouseSpider().scrape_catalog(config)
        else:
            spider_class = (
                DeepVellumSpider
                if request.provider in _DEEP_VELLUM_PROVIDERS
                else GenericBookSpider
            )
            spider = spider_class(config=config)
            records = await to_thread.run_sync(spider.to_json)

        return ScrapeResponse(
            provider=request.provider,
            status="success",
            records=records,
        )
    except CatalogUrlNotAllowedError as error:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Unsupported Deep Vellum catalog URL",
        ) from error
    except AstraHouseCatalogUrlNotAllowedError as error:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Astra House catalog URL is not allowlisted",
        ) from error
    except KeyError as error:
        raise sidecar_http_error(
            502,
            SidecarErrorCode.SCHEMA_CHANGED,
            "sidecar scrape response schema changed",
        ) from error
    except OSError as error:
        raise sidecar_http_error(
            502,
            SidecarErrorCode.NETWORK,
            "sidecar scrape network failure",
        ) from error
    except (RuntimeError, ValueError) as error:
        raise sidecar_runtime_error("scrape", error) from error


@router.post("/detail", responses=ERROR_RESPONSES)
async def scrape_detail(request: DetailScrapeRequest) -> DetailScrapeResponse:
    """Fetch and parse a single allowlisted publisher product detail page."""
    _ensure_detail_request(request)

    spider = DeepVellumStealthySpider()
    try:
        response = await StealthyFetcher.fetch_async(
            request.url, **spider.fetch_options
        )
    except OSError as error:
        raise sidecar_http_error(
            502,
            SidecarErrorCode.NETWORK,
            "sidecar detail network failure",
        ) from error
    try:
        detail_text = _response_text(response, request.max_bytes)
    except ResponseTooLargeError as error:
        raise sidecar_http_error(422, SidecarErrorCode.BLOCKED, str(error)) from error

    if detail_text.strip() == "":
        raise sidecar_http_error(
            422,
            SidecarErrorCode.EMPTY_RESPONSE,
            "sidecar detail returned an empty response",
        )

    if request.vendor in _TWO_LINES_PROVIDERS:
        try:
            detail = parse_two_lines_detail(detail_text)
        except (RuntimeError, ValueError) as error:
            raise sidecar_http_error(
                422,
                SidecarErrorCode.PARSE_FAILED,
                "sidecar detail failed to parse the response",
            ) from error
        return DetailScrapeResponse(
            vendor=request.vendor,
            source_uri=request.url,
            contributors=detail.contributors,
            isbn_13=detail.isbn_13,
            published_on=detail.published_on,
            cover={
                "source_url": detail.cover_url,
                "rights_basis": "local_cache_permitted",
                "attribution_text": f"Cover via {request.vendor}",
            },
            description=detail.description,
        )

    try:
        detail = spider._parse_detail(detail_text)
    except (RuntimeError, ValueError) as error:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.PARSE_FAILED,
            "sidecar detail failed to parse the response",
        ) from error
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
