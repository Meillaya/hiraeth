"""Deep Vellum-specific tests for the scrape router."""

from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.spiders.deep_vellum_stealthy import StealthyFetcher

client = TestClient(app)


class TestDeepVellumScrapeRouter:
    def test_scrape_endpoint_dispatches_deep_vellum_default_to_stealthy(self):
        with patch("app.routers.scrape.DeepVellumStealthySpider") as mock_stealthy_spider:
            mock_instance = mock_stealthy_spider.return_value
            mock_instance.scrape_catalog = AsyncMock(return_value=[{"title": "Stealthy Book"}])

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {
                        "start_urls": ["https://store.deepvellum.org/collections/all"],
                    },
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum_official_store"
            assert data["status"] == "success"
            assert data["records"] == [{"title": "Stealthy Book"}]
            mock_instance.scrape_catalog.assert_awaited_once_with(
                {
                    "start_urls": ["https://store.deepvellum.org/collections/all"],
                    "provider": "deep_vellum_official_store",
                }
            )

    def test_scrape_endpoint_rejects_deep_vellum_catalog_url_before_fetch(self) -> None:
        # Given: a caller-controlled Deep Vellum catalog URL aimed at instance metadata.
        with patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async:
            # When: the catalog scrape endpoint receives the unsafe URL.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {"catalog_url": "http://169.254.169.254/latest/meta-data/"},
                },
            )

        # Then: the endpoint rejects it before any fetch attempt.
        assert response.status_code == 422
        assert "Unsupported Deep Vellum catalog URL" in response.json()["detail"]
        fetch_async.assert_not_awaited()

    def test_scrape_endpoint_rejects_deep_vellum_start_url_before_fetch(self) -> None:
        # Given: a caller-controlled Deep Vellum start URL aimed at instance metadata.
        with patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async:
            # When: the catalog scrape endpoint receives the unsafe URL.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {"start_urls": ["http://169.254.169.254/latest/meta-data/"]},
                },
            )

        # Then: the endpoint rejects it before any fetch attempt.
        assert response.status_code == 422
        assert "Unsupported Deep Vellum catalog URL" in response.json()["detail"]
        fetch_async.assert_not_awaited()

    def test_scrape_endpoint_rejects_deep_vellum_legacy_start_url_before_spider(self) -> None:
        # Given: legacy spider dispatch config with a caller-controlled metadata URL.
        with (
            patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider,
            patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async,
        ):
            # When: the catalog scrape endpoint receives the unsafe URL.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {
                        "scraper": "spider",
                        "start_urls": ["http://169.254.169.254/latest/meta-data/"],
                    },
                },
            )

        # Then: the endpoint rejects it before any legacy spider or fetch can run.
        assert response.status_code == 422
        assert "Unsupported Deep Vellum catalog URL" in response.json()["detail"]
        mock_dv_spider.assert_not_called()
        fetch_async.assert_not_awaited()


    def test_scrape_endpoint_rejects_deep_vellum_legacy_flag_start_url_before_spider(self) -> None:
        # Given: legacy flag dispatch config with a caller-controlled metadata URL.
        with (
            patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider,
            patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async,
        ):
            # When: the catalog scrape endpoint receives the unsafe URL.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {
                        "use_stealthy_scraper": False,
                        "start_urls": ["http://169.254.169.254/latest/meta-data/"],
                    },
                },
            )

        # Then: the endpoint rejects it before any legacy spider or fetch can run.
        assert response.status_code == 422
        assert "Unsupported Deep Vellum catalog URL" in response.json()["detail"]
        mock_dv_spider.assert_not_called()
        fetch_async.assert_not_awaited()


    def test_scrape_endpoint_rejects_deep_vellum_legacy_multi_start_urls_before_spider(self) -> None:
        # Given: legacy spider dispatch with an allowed first URL and unsafe second URL.
        with (
            patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider,
            patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async,
        ):
            # When: the catalog scrape endpoint receives mixed start URLs.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {
                        "scraper": "spider",
                        "start_urls": [
                            "https://store.deepvellum.org/collections/all",
                            "http://169.254.169.254/latest/meta-data/",
                        ],
                    },
                },
            )

        # Then: every start URL is validated before legacy spider dispatch.
        assert response.status_code == 422
        assert "Unsupported Deep Vellum catalog URL" in response.json()["detail"]
        mock_dv_spider.assert_not_called()
        fetch_async.assert_not_awaited()

    def test_scrape_endpoint_rejects_deep_vellum_legacy_flag_multi_start_urls_before_spider(self) -> None:
        # Given: legacy flag dispatch with an allowed first URL and unsafe second URL.
        with (
            patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider,
            patch.object(StealthyFetcher, "fetch_async", new_callable=AsyncMock) as fetch_async,
        ):
            # When: the catalog scrape endpoint receives mixed start URLs.
            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {
                        "use_stealthy_scraper": False,
                        "start_urls": [
                            "https://store.deepvellum.org/collections/all",
                            "http://169.254.169.254/latest/meta-data/",
                        ],
                    },
                },
            )

        # Then: every start URL is validated before legacy spider dispatch.
        assert response.status_code == 422
        assert "Unsupported Deep Vellum catalog URL" in response.json()["detail"]
        mock_dv_spider.assert_not_called()
        fetch_async.assert_not_awaited()

    def test_scrape_endpoint_dispatches_deep_vellum_stealthy_by_scraper_config(self):
        with patch("app.routers.scrape.DeepVellumStealthySpider") as mock_stealthy_spider:
            mock_instance = mock_stealthy_spider.return_value
            mock_instance.scrape_catalog = AsyncMock(return_value=[{"title": "Stealthy Book"}])

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum",
                    "config": {"scraper": "stealthy"},
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum"
            assert data["records"] == [{"title": "Stealthy Book"}]
            mock_instance.scrape_catalog.assert_awaited_once_with(
                {"scraper": "stealthy", "provider": "deep_vellum"}
            )

    def test_scrape_endpoint_dispatches_deep_vellum_legacy_spider_by_scraper_config(self):
        with patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider:
            mock_instance = mock_dv_spider.return_value
            mock_instance.to_json.return_value = [{"title": "Legacy Deep Vellum Book"}]

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum",
                    "config": {
                        "start_urls": ["https://store.deepvellum.org/collections/all"],
                        "scraper": "spider",
                    },
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum"
            assert data["status"] == "success"
            assert data["records"] == [{"title": "Legacy Deep Vellum Book"}]
            mock_dv_spider.assert_called_once_with(
                config={
                    "start_urls": ["https://store.deepvellum.org/collections/all"],
                    "scraper": "spider",
                    "provider": "deep_vellum",
                }
            )

    def test_scrape_endpoint_dispatches_deep_vellum_legacy_spider_by_flag(self):
        with patch("app.routers.scrape.DeepVellumSpider") as mock_dv_spider:
            mock_instance = mock_dv_spider.return_value
            mock_instance.to_json.return_value = [{"title": "Legacy Deep Vellum Book"}]

            response = client.post(
                "/scrape/",
                json={
                    "provider": "deep_vellum_official_store",
                    "config": {"use_stealthy_scraper": False},
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "deep_vellum_official_store"
            assert data["records"] == [{"title": "Legacy Deep Vellum Book"}]
            mock_dv_spider.assert_called_once_with(
                config={"use_stealthy_scraper": False, "provider": "deep_vellum_official_store"}
            )

    def test_scrape_endpoint_dispatches_generic_book_spider_for_unknown_provider(self):
        with patch("app.routers.scrape.GenericBookSpider") as mock_generic_spider:
            mock_instance = mock_generic_spider.return_value
            mock_instance.to_json.return_value = [{"title": "Generic Book"}]

            response = client.post(
                "/scrape/",
                json={
                    "provider": "unknown_provider",
                    "config": {
                        "start_urls": ["http://example.com"],
                    },
                },
            )

            assert response.status_code == 200
            data = response.json()
            assert data["provider"] == "unknown_provider"
            assert data["status"] == "success"
            assert data["records"] == [{"title": "Generic Book"}]
            mock_generic_spider.assert_called_once_with(config={"start_urls": ["http://example.com"], "provider": "unknown_provider"})
