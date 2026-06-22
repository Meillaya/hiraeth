"""Deep Vellum helpers for the full-catalog generator."""

from __future__ import annotations

import argparse
import importlib
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from types import ModuleType
from typing import Any, TextIO, TypeAlias

JsonMap: TypeAlias = dict[str, Any]
MakeRecord: TypeAlias = Callable[
    [
        str,
        str,
        str,
        str,
        str,
        str,
        str,
        str | None,
        list[dict[str, str]],
        str | None,
        str | None,
        str | None,
        list[str] | None,
    ],
    JsonMap,
]
NormalizeFormat: TypeAlias = Callable[[str | None], str]
Isbn13: TypeAlias = Callable[[str | None], str | None]
ParseDate: TypeAlias = Callable[[str | None], str | None]
BuildShopify: TypeAlias = Callable[[str, set[str]], list[JsonMap]]
SpiderLoader: TypeAlias = Callable[[], type[Any] | None]
SpiderRunner: TypeAlias = Callable[[type[Any]], list[Mapping[str, Any]]]

DEEP_VELLUM_PROVIDER = "deep_vellum_official_store"
DEEP_VELLUM_ALLOWED_VENDORS = {"Deep Vellum", "Deep Vellum Publishing"}


def parse_catalog_args(providers: Mapping[str, Mapping[str, Any]], argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Refresh full-catalog fixtures from authorized public publisher sources.",
    )
    parser.add_argument(
        "--provider",
        choices=sorted(providers),
        help="Build only one provider instead of the full catalog.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build and report records without writing catalog JSON files.",
    )
    return parser.parse_args(argv)


def load_deep_vellum_stealthy_spider() -> type[Any] | None:
    sidecar_path = Path(__file__).resolve().parents[1] / "sidecar"
    if sidecar_path.exists():
        sidecar = str(sidecar_path)
        if sidecar not in sys.path:
            sys.path.insert(0, sidecar)

    try:
        module = importlib.import_module("app.spiders.deep_vellum_stealthy")
        return getattr(module, "DeepVellumStealthySpider")
    except (ImportError, AttributeError) as exc:
        print(
            "warning: Deep Vellum stealthy spider unavailable "
            f"({exc}); falling back to Shopify products.json",
            file=sys.stderr,
        )
        return None


def _sidecar_site_packages() -> Path:
    version = f"python{sys.version_info.major}.{sys.version_info.minor}"
    return Path(__file__).resolve().parents[1] / "sidecar" / ".venv" / "lib" / version / "site-packages"


def import_anyio() -> ModuleType:
    try:
        return importlib.import_module("anyio")
    except ModuleNotFoundError:
        site_packages = _sidecar_site_packages()
        if site_packages.exists():
            sys.path.insert(0, str(site_packages))
            return importlib.import_module("anyio")
        raise


def _spider_string(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _spider_mapping(value: Any) -> Mapping[str, Any]:
    return value if isinstance(value, Mapping) else {}


def _spider_contributors(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, Sequence) or isinstance(value, str):
        return []

    contributors: list[dict[str, str]] = []
    for item in value:
        if not isinstance(item, Mapping):
            continue
        name = _spider_string(item.get("name"))
        if not name:
            continue
        contributors.append({"name": name, "role": _spider_string(item.get("role")) or "author"})
    return contributors


def _spider_subjects(value: Any) -> list[str] | None:
    if not isinstance(value, Sequence) or isinstance(value, str):
        return None

    subjects = [subject.strip() for subject in value if isinstance(subject, str) and subject.strip()]
    return subjects or None


def _first_source_uri(provider_config: Mapping[str, Any]) -> str:
    source_urls = provider_config.get("source_urls")
    if isinstance(source_urls, Sequence) and not isinstance(source_urls, str) and source_urls:
        return str(source_urls[0])
    return ""


def deep_vellum_record_from_spider(
    record: Mapping[str, Any],
    provider_config: Mapping[str, Any],
    make_record: MakeRecord,
    normalize_format: NormalizeFormat,
    isbn13: Isbn13,
    parse_date: ParseDate,
) -> JsonMap:
    work = _spider_mapping(record.get("work"))
    edition = _spider_mapping(record.get("edition"))
    cover = _spider_mapping(record.get("cover"))
    title = _spider_string(work.get("title")) or _spider_string(edition.get("title")) or "Untitled"
    source_uri = (
        _spider_string(record.get("source_uri"))
        or _spider_string(record.get("storefront_url"))
        or _first_source_uri(provider_config)
    )
    source_product_id = _spider_string(record.get("source_product_id")) or source_uri.rstrip("/").rsplit("/", 1)[-1] or title

    return make_record(
        DEEP_VELLUM_PROVIDER,
        str(provider_config["publisher"]),
        str(provider_config["source_type"]),
        source_uri,
        source_product_id,
        title,
        normalize_format(_spider_string(edition.get("format"))),
        isbn13(_spider_string(edition.get("isbn_13"))),
        _spider_contributors(record.get("contributors")),
        _spider_string(cover.get("source_url")),
        parse_date(_spider_string(edition.get("published_on"))),
        _spider_string(record.get("description")),
        _spider_subjects(work.get("subjects")),
    )


async def _scrape_spider_records(spider_class: type[Any]) -> list[Mapping[str, Any]]:
    records = await spider_class().scrape_catalog({"provider": DEEP_VELLUM_PROVIDER})
    if not isinstance(records, Sequence) or isinstance(records, str):
        return []
    return [record for record in records if isinstance(record, Mapping)]


def _run_spider_records(spider_class: type[Any]) -> list[Mapping[str, Any]]:
    anyio = import_anyio()
    return anyio.run(_scrape_spider_records, spider_class)


def build_deep_vellum_catalog(
    provider_config: Mapping[str, Any],
    make_record: MakeRecord,
    normalize_format: NormalizeFormat,
    isbn13: Isbn13,
    parse_date: ParseDate,
    build_shopify: BuildShopify,
    spider_loader: SpiderLoader = load_deep_vellum_stealthy_spider,
    spider_runner: SpiderRunner = _run_spider_records,
    stderr: TextIO = sys.stderr,
) -> list[JsonMap]:
    spider_class = spider_loader()
    if spider_class is None:
        print("warning: falling back to Shopify products.json for deep_vellum_official_store", file=stderr)
        return build_shopify(DEEP_VELLUM_PROVIDER, DEEP_VELLUM_ALLOWED_VENDORS)

    print("building deep_vellum_official_store with stealthy spider", file=stderr)
    records = spider_runner(spider_class)
    return [
        deep_vellum_record_from_spider(record, provider_config, make_record, normalize_format, isbn13, parse_date)
        for record in records
    ]
