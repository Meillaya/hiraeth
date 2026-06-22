"""Deep Vellum Scrapling spider with vendor filtering and load-more pagination."""

import json
import re
from collections.abc import AsyncGenerator, Generator
from typing import Any, Callable, cast

from scrapling.spiders import Request, Response

from app.spiders.base_spider import BaseSpider


class DeepVellumSpider(BaseSpider):
    """Spider for Deep Vellum's Shopify Sparq catalog.

    Extracts book records from the catalog grid at
    ``https://store.deepvellum.org/collections/all``, filters to Deep Vellum
    vendors, follows product detail pages for bibliographic enrichment, and
    handles the Sparq ``LOAD MORE`` pagination button.
    """

    name = "deep_vellum"
    allowed_vendors = {"Deep Vellum", "Deep Vellum Publishing"}
    base_url = "https://store.deepvellum.org"
    default_start_url = "https://store.deepvellum.org/collections/all"

    def __init__(
        self,
        config: dict[str, Any] | None = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(config=config, **kwargs)
        self.provider = self.config.get("provider", "deep_vellum_official_store")
        if not self.start_urls:
            self.start_urls = [self.default_start_url]
        self.max_pages = self.config.get("max_pages", 10)
        self._pages_seen = 0

    async def parse(self, response: Response) -> Any:
        """Parse the catalog grid and dispatch detail-page requests."""
        self._pages_seen += 1
        products = self._extract_shopify_products(response)

        if products:
            for request in self._parse_json_products(response, products):
                yield request
        else:
            for request in self._parse_css_cards(response):
                yield request

        if self._pages_seen < self.max_pages:
            load_more = response.css(".sparq-load-more button")
            if load_more:
                next_url = self._load_more_url(response, load_more)
                if next_url:
                    yield response.follow(
                        next_url,
                        callback=self._parse_catalog_page,
                    )

    def _parse_json_products(
        self,
        response: Response,
        products: list[dict[str, Any]],
    ) -> Generator[Request, None, None]:
        """Dispatch detail requests using embedded Shopify JSON products."""
        for product in products:
            vendor = product.get("vendor")
            if not self.is_allowed_vendor(vendor):
                continue

            handle = product.get("handle")
            title = product.get("title")
            if not handle or not title:
                continue

            detail_url = f"{self.base_url}/products/{handle}"
            variants = product.get("variants") or []
            variant_sku = variants[0].get("sku") if variants else None

            grid_data = {
                "title": title,
                "vendor": self.normalize_vendor(vendor),
                "handle": handle,
                "source_uri": detail_url,
                "cover_url": None,
                "variant_sku": variant_sku,
            }

            yield response.follow(
                detail_url,
                callback=self.parse_detail,
                meta={"grid_data": grid_data},
            )

    def _parse_css_cards(
        self,
        response: Response,
    ) -> Generator[Request, None, None]:
        """Fallback dispatch using CSS card selectors."""
        products = self._extract_shopify_products(response)
        title_to_product = {p["title"]: p for p in products}

        for card in response.css(".sparq-result-inner"):
            title = self._text(card, ".sparq-item-title::text")
            vendor = self._text(card, ".vendor-title::text")
            if not title or not self.is_allowed_vendor(vendor):
                continue

            product = title_to_product.get(title)
            if not product:
                continue

            handle = product.get("handle")
            if not handle:
                continue

            cover_url = self.cover_url(card)
            detail_url = f"{self.base_url}/products/{handle}"

            grid_data = {
                "title": title,
                "vendor": self.normalize_vendor(vendor),
                "cover_url": cover_url,
                "handle": handle,
                "source_uri": detail_url,
                "variant_sku": product.get("variant_sku"),
            }

            yield response.follow(
                detail_url,
                callback=self.parse_detail,
                meta={"grid_data": grid_data},
            )

    async def _parse_catalog_page(
        self, response: Response
    ) -> AsyncGenerator[dict[str, Any] | Request | None, None]:
        """Re-enter the catalog parser for a follow-up page."""
        parse = cast(
            Callable[[Response], AsyncGenerator[dict[str, Any] | Request | None, None]],
            self.parse,
        )
        async for item in parse(response):
            yield item

    async def parse_detail(
        self, response: Response
    ) -> AsyncGenerator[dict[str, Any] | Request | None, None]:
        """Parse a product detail page and emit a ``BookRecord``."""
        grid_data = response.meta.get("grid_data", {})

        title = self._text(response, "h1.product-single__title::text") or grid_data.get("title")
        description = self._all_text(response, ".product-single__description.rte")
        contributor_line = self._all_text(response, ".product-single__description.rte > p:first-of-type")

        isbn_13 = self._extract_isbn(description)
        published_on = self._extract_publication_date(description)
        contributors = self._extract_contributors(contributor_line)

        # Fall back to the embedded Shopify variant SKU if the detail page
        # regex misses the ISBN.
        if not isbn_13:
            isbn_13 = grid_data.get("variant_sku")

        source_uri = grid_data.get("source_uri", response.url)
        publisher = grid_data.get("vendor") or "Deep Vellum Publishing"

        record: dict[str, Any] = {
            "provider": self.provider,
            "source_uri": source_uri,
            "source_product_id": grid_data.get("handle"),
            "publisher": publisher,
            "imprint": None,
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
                "format": "Paperback",
                "published_on": published_on,
                "isbn_13": isbn_13,
                "language_code": None,
                "page_count": None,
                "dimensions": None,
            },
            "contributors": contributors,
            "cover": {
                "source_url": grid_data.get("cover_url"),
                "rights_basis": "local_cache_permitted",
                "attribution_text": f"Cover via {self.provider}",
            },
            "field_sources": {
                "title": {"provider": self.provider, "source_uri": source_uri},
                "publisher": {"provider": self.provider, "source_uri": source_uri},
                "cover": {"provider": self.provider, "source_uri": source_uri},
                "isbn_13": {"provider": self.provider, "source_uri": response.url},
                "published_on": {"provider": self.provider, "source_uri": response.url},
                "description": {"provider": self.provider, "source_uri": response.url},
                "contributors": {"provider": self.provider, "source_uri": response.url},
            },
        }

        if description:
            record["description"] = description

        yield record

    def _extract_shopify_products(self, response: Response) -> list[dict[str, Any]]:
        """Extract product metadata from embedded ``window.ShopifyAnalytics.meta``."""
        for script in response.css("script::text"):
            text = script.get()
            if not text or "ShopifyAnalytics" not in text:
                continue

            products = self._parse_meta_object_products(text)
            if products:
                return products
            products = self._parse_meta_products_array(text)
            if products:
                return products
        return []

    def _parse_meta_object_products(self, text: str) -> list[dict[str, Any]] | None:
        match = re.search(
            r"window\.ShopifyAnalytics\.meta\s*=\s*(\{.*?\});",
            text,
            re.DOTALL,
        )
        if not match:
            return None
        try:
            data = json.loads(match.group(1))
            products = data.get("products") or data.get("product")
            if isinstance(products, list):
                return self._with_variant_skus(products)
        except json.JSONDecodeError:
            pass
        return None

    def _parse_meta_products_array(self, text: str) -> list[dict[str, Any]] | None:
        match = re.search(
            r"window\.ShopifyAnalytics\.meta\.products\s*=\s*(\[.*?\]);",
            text,
            re.DOTALL,
        )
        if not match:
            return None
        try:
            products = json.loads(match.group(1))
            if isinstance(products, list):
                return self._with_variant_skus(products)
        except json.JSONDecodeError:
            pass
        return None

    @staticmethod
    def _with_variant_skus(products: list[dict[str, Any]]) -> list[dict[str, Any]]:
        for product in products:
            variants = product.get("variants") or []
            if variants:
                product["variant_sku"] = variants[0].get("sku")
        return products

    def is_allowed_vendor(self, vendor: str | None) -> bool:
        if not vendor:
            return False
        return self.normalize_vendor(vendor) is not None

    def normalize_vendor(self, vendor: str | None) -> str | None:
        if not vendor:
            return None
        normalized = vendor.strip().lower()
        for allowed in self.allowed_vendors:
            if normalized == allowed.lower():
                return allowed
        return None

    @staticmethod
    def _text(node: Any, selector: str) -> str | None:
        result = node.css(selector).get()
        return result.strip() if result else None

    @staticmethod
    def _all_text(node: Any, selector: str) -> str | None:
        """Return recursively joined text for an element and its descendants."""
        results = node.css(f"{selector} ::text").getall()
        if not results:
            return None
        text = " ".join(r.strip() for r in results if r.strip())
        return text if text else None

    def cover_url(self, card: Any) -> str | None:
        images = card.css(".sq-product-image img.item-image")
        if not images:
            return None
        img = images[0]
        src = img.attrib.get("src") or ""
        data_src = img.attrib.get("data-src") or ""
        if "sq-image-loader.svg" in src and data_src:
            return data_src.strip()
        return (data_src or src).strip() or None

    def _extract_isbn(self, text: str | None) -> str | None:
        if not text:
            return None
        match = re.search(r"Paperback:\s*(\d{13})", text)
        return match.group(1) if match else None

    def _extract_publication_date(self, text: str | None) -> str | None:
        if not text:
            return None
        match = re.search(
            r"Publication Date:\s*(.+?)(?=\s+(?:Paperback|By|Translated|$))",
            text,
        )
        return match.group(1).strip() if match else None

    def _extract_contributors(self, text: str | None) -> list[dict[str, str]]:
        """Extract author and translator from the first description paragraph."""
        if not text:
            return []
        match = re.search(r"By\s+(.+)", text)
        if not match:
            return []
        clause = match.group(1).strip()
        parts = re.split(r"\s+Translated by\s+", clause, maxsplit=1)
        contributors: list[dict[str, str]] = [
            {"name": parts[0].strip(), "role": "author"}
        ]
        if len(parts) > 1:
            contributors.append({"name": parts[1].strip(), "role": "translator"})
        return contributors

    def _load_more_url(self, response: Response, load_more: Any) -> str | None:
        """Resolve a followable URL from the Sparq load-more button."""
        button = load_more[0] if hasattr(load_more, "__getitem__") else load_more
        for attr in ("data-url", "data-href", "data-next", "data-page-url"):
            url = button.attrib.get(attr)
            if url:
                return response.urljoin(url)
        parent = getattr(button, "parent", None)
        if parent is not None:
            for attr in ("data-url", "data-href", "data-next", "data-page-url"):
                url = parent.attrib.get(attr)
                if url:
                    return response.urljoin(url)
        return None
