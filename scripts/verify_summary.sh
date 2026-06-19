#!/usr/bin/env bash
set -euo pipefail

QA_DIR="${QA_DIR:-artifacts/qa}"
SUMMARY_DIR="${QA_DIR}/verify"
SUMMARY_JSON="${SUMMARY_DIR}/summary.json"
mkdir -p "${SUMMARY_DIR}"

python - <<'PY'
import json
import re
from pathlib import Path

root = Path.cwd()
qa_dir = Path("artifacts/qa")
summary_path = qa_dir / "verify" / "summary.json"

mix_text = (root / "mix.exs").read_text() + "\n" + (root / "mix.lock").read_text()
router_text = (root / "lib/hiraeth_web/router.ex").read_text()

required_domains = ["Catalog", "Sources", "Covers", "Imports", "Search", "Audit"]
required_routes = [
    'live "/"',
    'live "/browse"',
    'live "/search"',
    'live "/publishers"',
    'live "/publishers/:slug"',
    'live "/series"',
    'live "/series/:slug"',
    'live "/editions/:slug"',
]

artifact_expectations = {
    "bootstrap_check": qa_dir / "bootstrap/bootstrap-check.txt",
    "test_elixir": qa_dir / "elixir/test-elixir.txt",
    "test_ui": qa_dir / "ui/test-ui.txt",
    "test_ingest": qa_dir / "ingest/test-ingest.txt",
    "test_normalize": qa_dir / "normalize/test-normalize.txt",
    "test_covers": qa_dir / "covers/test-covers.txt",
    "audit_provenance": qa_dir / "provenance/audit-provenance.txt",
    "test_browser": qa_dir / "browser/test-browser.txt",
}

source_ledger = qa_dir / "provenance/source-ledger.csv"
provenance_json = qa_dir / "provenance/audit-provenance.json"
network_json = qa_dir / "browser/network-errors.json"
keyboard_json = qa_dir / "browser/keyboard-focus.json"

artifact_gates = {
    name: path.exists() and f"{name}=pass" in path.read_text(errors="replace")
    for name, path in artifact_expectations.items()
}

if provenance_json.exists():
    provenance_data = json.loads(provenance_json.read_text())
else:
    provenance_data = {}

if network_json.exists():
    network_data = json.loads(network_json.read_text())
else:
    network_data = {"page_failures": ["missing"], "broken_local_resources": ["missing"]}

if keyboard_json.exists():
    keyboard_data = json.loads(keyboard_json.read_text())
else:
    keyboard_data = {"passed": False}

exact_bad_deps = re.compile(r'(^|[ {:"\'])(oban|react|vite|vitest)([,"\' ]|$)', re.I)
root_package = root / "package.json"
root_vite = list(root.glob("vite.config.*"))

summary = {
    "gates": {
        "no_react": not root_package.exists() and not root_vite and not (root / "assets/app").exists() and not exact_bad_deps.search(mix_text),
        "no_broad_json_api": not re.search(r'scope\s+"/api|forward\s+"/api|/api/', router_text),
        "no_oban": not re.search(r'(^|[ {:"\'])oban([,"\' ]|$)', mix_text, re.I),
        "ash_domains": all((root / f"lib/hiraeth/{domain.lower()}.ex").exists() and f"defmodule Hiraeth.{domain}" in (root / f"lib/hiraeth/{domain.lower()}.ex").read_text() for domain in required_domains),
        "liveview_routes": all(route in router_text for route in required_routes),
        "provenance": (
            source_ledger.exists()
            and provenance_json.exists()
            and provenance_data.get("missing_provenance") == []
            and provenance_data.get("source_ledger_missing") == []
            and provenance_data.get("invalid_public_covers") == []
            and provenance_data.get("long_copied_text") == []
        ),
        "browser": (
            network_data.get("page_failures") == []
            and network_data.get("broken_local_resources") == []
            and keyboard_data.get("passed") is True
        ),
        "local_targets": all(artifact_gates.values()),
    },
    "artifacts": {name: str(path) for name, path in artifact_expectations.items()},
    "artifact_gates": artifact_gates,
    "notes": {
        "browser_keyboard_focus": str(keyboard_json),
        "browser_network": str(network_json),
        "provenance_source_ledger": str(source_ledger),
    },
}

summary["passed"] = all(summary["gates"].values())
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

if not summary["passed"]:
    print(json.dumps(summary, indent=2, sort_keys=True))
    raise SystemExit(1)

print(f"verify_summary=pass path={summary_path}")
PY
