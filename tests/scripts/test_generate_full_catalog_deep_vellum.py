from __future__ import annotations

import importlib.util
import io
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "generate_full_catalog.py"
HELPER = ROOT / "scripts" / "generate_full_catalog_deep_vellum.py"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakeDeepVellumStealthySpider:
    pass


def fake_spider_records(spider_class):
    assert spider_class is FakeDeepVellumStealthySpider
    return [
        {
            "provider": "deep_vellum_official_store",
            "source_uri": "https://store.deepvellum.org/products/test-book",
            "source_product_id": "test-book",
            "work": {"title": "Test Book", "subjects": ["Fiction"]},
            "edition": {
                "title": "Test Book",
                "format": "Paperback",
                "published_on": "June 1, 2026",
                "isbn_13": "9781646054008",
            },
            "contributors": [{"name": "A. Writer", "role": "author"}],
            "cover": {"source_url": "https://cdn.shopify.com/test.jpg"},
            "description": "A deterministic fixture description for the stealthy spider adapter.",
        }
    ]


def test_build_deep_vellum_uses_stealthy_spider_when_importable():
    script = load_module(SCRIPT, "generate_full_catalog_under_test")
    helper = load_module(HELPER, "generate_full_catalog_deep_vellum_under_test")
    stderr = io.StringIO()

    records = helper.build_deep_vellum_catalog(
        script.PROVIDERS[helper.DEEP_VELLUM_PROVIDER],
        script.make_record,
        script.normalize_format,
        script.isbn13,
        script.parse_date,
        script.build_shopify,
        spider_loader=lambda: FakeDeepVellumStealthySpider,
        spider_runner=fake_spider_records,
        stderr=stderr,
    )

    assert len(records) == 1
    record = records[0]
    assert record["source_uri"] == "https://store.deepvellum.org/products/test-book"
    assert record["work"]["title"] == "Test Book"
    assert record["edition"]["format"] == "paperback"
    assert record["edition"]["published_on"] == "2026-06-01"
    assert record["edition"]["isbn_13"] == "9781646054008"
    assert record["contributors"] == [{"name": "A. Writer", "role": "author"}]
    assert "stealthy spider" in stderr.getvalue()


def test_build_deep_vellum_falls_back_to_shopify_when_spider_unavailable():
    script = load_module(SCRIPT, "generate_full_catalog_under_test")
    helper = load_module(HELPER, "generate_full_catalog_deep_vellum_under_test")
    stderr = io.StringIO()
    called = {}

    def fake_build_shopify(provider, allowed_vendors):
        called["provider"] = provider
        called["allowed_vendors"] = allowed_vendors
        return []

    assert helper.build_deep_vellum_catalog(
        script.PROVIDERS[helper.DEEP_VELLUM_PROVIDER],
        script.make_record,
        script.normalize_format,
        script.isbn13,
        script.parse_date,
        fake_build_shopify,
        spider_loader=lambda: None,
        stderr=stderr,
    ) == []
    assert called == {
        "provider": "deep_vellum_official_store",
        "allowed_vendors": {"Deep Vellum", "Deep Vellum Publishing"},
    }
    assert "falling back" in stderr.getvalue().lower()
