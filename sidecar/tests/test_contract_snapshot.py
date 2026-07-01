from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Final

import pytest

from app.main import app

FIXTURE_DIR: Final = Path(__file__).parent / "fixtures" / "contract_snapshots"
DEFAULT_SNAPSHOT: Final = FIXTURE_DIR / "openapi.json"
SNAPSHOT_ENV: Final = "HIRAETH_CONTRACT_SNAPSHOT"


def _canonical_openapi() -> str:
    return json.dumps(app.openapi(), indent=2, sort_keys=True) + "\n"


def _snapshot_path() -> Path:
    configured = os.environ.get(SNAPSHOT_ENV)
    if configured:
        return Path(configured)
    return DEFAULT_SNAPSHOT


def _assert_openapi_matches_snapshot(snapshot_path: Path) -> None:
    expected = snapshot_path.read_text(encoding="utf-8")
    actual = _canonical_openapi()

    assert actual == expected, (
        "OpenAPI contract snapshot mismatch. Review the private sidecar shape, "
        f"then update {snapshot_path} only when the change is intentional."
    )


def test_openapi_snapshot_matches_private_contract() -> None:
    # Given: the reviewed private OpenAPI snapshot for the sidecar.
    snapshot_path = _snapshot_path()

    # When: FastAPI renders the current route/schema contract.
    # Then: it matches the reviewed private ingestion contract.
    _assert_openapi_matches_snapshot(snapshot_path)


def test_openapi_snapshot_rejects_mismatch() -> None:
    # Given: a snapshot path supplied by the caller that does not match the app.
    configured = os.environ.get(SNAPSHOT_ENV)
    snapshot_path = Path(configured) if configured else FIXTURE_DIR / "openapi_mismatch.json"

    # When/Then: the helper rejects the stale or unreviewed contract shape.
    with pytest.raises(AssertionError, match="OpenAPI contract snapshot mismatch"):
        _assert_openapi_matches_snapshot(snapshot_path)


def test_openapi_snapshot_rejects_malformed_snapshot() -> None:
    # Given: a snapshot fixture that is not canonical OpenAPI JSON.
    snapshot_path = FIXTURE_DIR / "openapi_malformed.json"

    # When/Then: malformed reviewed data is treated as a mismatch.
    with pytest.raises(AssertionError, match="OpenAPI contract snapshot mismatch"):
        _assert_openapi_matches_snapshot(snapshot_path)
