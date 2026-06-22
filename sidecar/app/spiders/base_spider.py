"""Base Scrapling spider with structured item extraction and JSON output."""

from typing import Any

from scrapling.fetchers import FetcherSession, StealthySession
from scrapling.spiders import Response, Spider


class BaseSpider(Spider):
    """Base spider with configurable rate limiting, blocked retry, and JSON output."""

    name = "base"
    download_delay = 0
    concurrent_requests = 4
    max_blocked_retries = 3

    def __init__(
        self,
        config: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        self.config = config or {}
        self.start_urls = self.config.get("start_urls", [])
        self.download_delay = self.config.get("download_delay", 0)
        self.concurrent_requests = self.config.get("concurrent_requests", 4)
        self.max_blocked_retries = self.config.get("max_blocked_retries", 3)
        self.use_stealthy = self.config.get("use_stealthy_fetcher", False)
        super().__init__(**kwargs)

    def configure_sessions(self, manager: Any) -> None:
        """Configure the session manager with Fetcher or StealthySession."""
        if self.use_stealthy:
            manager.add("default", StealthySession())
        else:
            manager.add("default", FetcherSession())

    async def parse(self, response: Response) -> Any:
        """Parse a response and yield structured items.

        Subclasses must override this method.
        """
        raise NotImplementedError("Subclasses must implement parse()")

    def to_json(self) -> list[dict[str, Any]]:
        """Run the spider and return scraped items as a JSON-serializable list."""
        result = self.start()
        return list(result.items)
