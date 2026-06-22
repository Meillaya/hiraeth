from fastapi import APIRouter

from app.models import ScrapeRequest, ScrapeResponse
from app.spiders.deep_vellum_spider import DeepVellumSpider
from app.spiders.generic_book_spider import GenericBookSpider

router = APIRouter(prefix="/scrape", tags=["scrape"])


@router.post("/")
def scrape_catalog(request: ScrapeRequest) -> ScrapeResponse:
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
    if request.provider in ("deep_vellum", "deep_vellum_official_store"):
        spider_class = DeepVellumSpider
    else:
        spider_class = GenericBookSpider

    spider = spider_class(config=config)
    try:
        records = spider.to_json()
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
