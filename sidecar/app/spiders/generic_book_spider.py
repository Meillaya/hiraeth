"""Configurable generic book spider with CSS/XPath selector support."""

from typing import Any

from scrapling.spiders import Response

from app.spiders.base_spider import BaseSpider


class GenericBookSpider(BaseSpider):
    """Spider that extracts book metadata using configurable CSS/XPath selectors."""

    name = "generic_book"

    async def parse(self, response: Response) -> Any:
        """Extract book records from the response using configured selectors."""
        selectors = self.config.get("selectors", {})
        provider = self.config.get("provider", "unknown")

        item_selector = selectors.get("item", ".book")
        title_sel = selectors.get("title", "h2::text")
        author_sel = selectors.get("author", ".author::text")
        publisher_sel = selectors.get("publisher", ".publisher::text")
        isbn_sel = selectors.get("isbn", ".isbn::text")
        cover_sel = selectors.get("cover", ".cover::attr(src)")
        description_sel = selectors.get("description", ".description::text")
        publication_date_sel = selectors.get("publication_date", ".date::text")

        items = response.xpath(item_selector) if item_selector.startswith("//") else response.css(item_selector)
        for item in items:
            title = self._extract(item, title_sel)
            author = self._extract(item, author_sel)
            publisher = self._extract(item, publisher_sel)
            isbn = self._extract(item, isbn_sel)
            cover_url = self._extract(item, cover_sel)
            description = self._extract(item, description_sel)
            publication_date = self._extract(item, publication_date_sel)

            contributors = []
            if author:
                contributors.append({"name": author, "role": "author"})

            record: dict[str, Any] = {
                "provider": provider,
                "source_uri": response.url,
                "work": {
                    "title": title,
                    "subtitle": None,
                    "original_title": None,
                    "original_language_code": None,
                    "subjects": [],
                },
                "edition": {
                    "title": title,
                    "subtitle": None,
                    "format": None,
                    "published_on": publication_date,
                    "isbn_13": isbn,
                    "language_code": None,
                    "page_count": None,
                    "dimensions": None,
                },
                "contributors": contributors,
                "cover": {
                    "source_url": cover_url,
                    "rights_basis": "local_cache_permitted",
                    "attribution_text": f"Cover via {provider}",
                },
                "field_sources": {
                    "title": {"provider": provider, "source_uri": response.url},
                    "author": {"provider": provider, "source_uri": response.url},
                    "publisher": {"provider": provider, "source_uri": response.url},
                    "isbn_13": {"provider": provider, "source_uri": response.url},
                    "cover": {"provider": provider, "source_uri": response.url},
                    "description": {"provider": provider, "source_uri": response.url},
                    "published_on": {"provider": provider, "source_uri": response.url},
                },
            }

            if description:
                record["description"] = description

            yield record

    @staticmethod
    def _extract(item: Any, selector: str | None) -> str | None:
        """Safely extract text from a selector string.

        Supports both CSS and XPath selectors.
        """
        if not selector:
            return None
        result = item.css(selector).get() if not selector.startswith("//") else item.xpath(selector).get()
        return result.strip() if result else None
