from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "generate_full_catalog.py"


def load_script_module():
    spec = importlib.util.spec_from_file_location("generate_full_catalog_under_test", SCRIPT)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_help_exits_without_running_builders():
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--help"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert "--provider" in result.stdout
    assert "--dry-run" in result.stdout
    assert "building " not in result.stderr


def test_provider_dry_run_builds_selected_provider_without_writing(monkeypatch, tmp_path, capsys):
    module = load_script_module()
    provider = "deep_vellum_official_store"
    output_dir = tmp_path / "catalog"
    calls = []

    def fake_builder():
        calls.append(provider)
        return [
            module.make_record(
                provider,
                "Deep Vellum",
                "publisher_dataset",
                "https://store.deepvellum.org/products/dry-run-book",
                "dry-run-book",
                "Dry Run Book",
                "paperback",
                "9781646054008",
                [{"name": "Dry Runner", "role": "author"}],
                "https://cdn.shopify.com/dry-run-book.jpg",
                "2026-06-01",
                "Deterministic dry-run description.",
                ["Fiction"],
            )
        ]

    def forbidden_builder():
        raise AssertionError("unselected provider should not build")

    monkeypatch.setattr(module, "OUT_DIR", output_dir)
    monkeypatch.setattr(
        module,
        "catalog_builders",
        lambda: {
            provider: fake_builder,
            "dalkey_archive_official_store": forbidden_builder,
        },
    )

    assert module.main(["--provider", provider, "--dry-run"]) == 0

    assert calls == [provider]
    assert not output_dir.exists()
    captured = capsys.readouterr()
    assert f"dry-run {provider}" in captured.err
    assert "records=1" in captured.err


def test_unknown_provider_exits_before_building(monkeypatch):
    module = load_script_module()
    monkeypatch.setattr(
        module,
        "catalog_builders",
        lambda: {"deep_vellum_official_store": lambda: pytest.fail("should not build")},
    )

    with pytest.raises(SystemExit) as error:
        module.main(["--provider", "unknown_provider", "--dry-run"])

    assert error.value.code == 2
