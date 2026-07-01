#!/usr/bin/env python3
"""Deterministic sidecar SSRF/private-host rejection probe for T25."""

from __future__ import annotations

import json
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sidecar"))

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402
from app.models import JsonObject  # noqa: E402
from app.routers import fetch as fetch_router  # noqa: E402

PRIVATE_ENDPOINT = (
    "https://127.0.0.1/private-probe?token=SECRET_TOKEN&password=SECRET_PASSWORD"
)
USERINFO_ENDPOINT = (
    "https://probe-user:SECRET_PASSWORD@example.com/private-probe?token=SECRET_TOKEN"
)
DENYLIST = (
    "Traceback",
    "Stacktrace",
    "SECRET_TOKEN",
    "SECRET_PASSWORD",
    "probe-user",
    "COOKIE",
    "password=",
    "token=",
    "127.0.0.1",
    PRIVATE_ENDPOINT,
    USERINFO_ENDPOINT,
)
PRIVATE_MESSAGE_TERMS = ("private", "loopback", "link-local", "unspecified")
CASES = (
    ("private_host", PRIVATE_ENDPOINT, ("127.0.0.1",), ("host",), PRIVATE_MESSAGE_TERMS),
    ("userinfo", USERINFO_ENDPOINT, ("example.com",), ("userinfo",), ()),
)


def main() -> int:
    adapter_executed = False

    async def sentinel_adapter(_config: JsonObject) -> list[JsonObject]:
        nonlocal adapter_executed
        adapter_executed = True
        return []

    original_adapter = fetch_router.ADAPTERS["shopify"]
    fetch_router.ADAPTERS["shopify"] = sentinel_adapter

    try:
        client = TestClient(app)

        for case_name, endpoint, source_hosts, required_terms, any_terms in CASES:
            adapter_executed = False
            response = client.post(
                "/fetch/",
                json={
                    "provider": f"t25_private_host_probe_{case_name}",
                    "config": {
                        "api": {"type": "shopify", "endpoint": endpoint},
                        "source_hosts": list(source_hosts),
                        "rate_limit": {"min_delay_ms": 0, "max_bytes": 4096},
                    },
                },
            )

            result = assert_safe_rejection(
                case_name,
                response.status_code,
                response.text,
                response.json(),
                adapter_executed=adapter_executed,
                required_terms=required_terms,
                any_terms=any_terms,
            )
            if result != 0:
                return result
    finally:
        fetch_router.ADAPTERS["shopify"] = original_adapter

    print(
        "PASS sidecar private-host rejection blocked unsafe endpoints "
        "status=422 code=invalid_host safe_error=true cases=2"
    )
    return 0


def assert_safe_rejection(
    case_name: str,
    status_code: int,
    body: str,
    data: JsonObject,
    *,
    adapter_executed: bool,
    required_terms: tuple[str, ...],
    any_terms: tuple[str, ...],
) -> int:
    if status_code != 422:
        print(
            f"FAIL sidecar {case_name} rejection expected status=422 "
            f"actual={status_code}"
        )
        print(body)
        return 1

    detail = data.get("detail", {})
    if isinstance(detail, str):
        code = data.get("code")
        message = detail
    elif isinstance(detail, dict):
        code = detail.get("code")
        raw_message = detail.get("message", "")
        message = raw_message if isinstance(raw_message, str) else ""
    else:
        code = data.get("code")
        message = ""

    if code != "invalid_host":
        print(
            f"FAIL sidecar {case_name} rejection expected code=invalid_host "
            f"actual={code!r}"
        )
        print(json.dumps(data, sort_keys=True))
        return 1

    leaked_tokens = [token for token in DENYLIST if token in body]
    if leaked_tokens:
        print(f"FAIL sidecar {case_name} rejection leaked unsafe diagnostic text")
        print(json.dumps({"leaked_tokens": leaked_tokens, "body": body}, sort_keys=True))
        return 1

    if adapter_executed:
        print(f"FAIL sidecar {case_name} rejection executed fetch adapter")
        print(json.dumps(data, sort_keys=True))
        return 1

    normalized_message = message.lower()
    if not all(term in normalized_message for term in required_terms) or (
        any_terms and not any(term in normalized_message for term in any_terms)
    ):
        print(f"FAIL sidecar {case_name} rejection missing safe denial category")
        print(json.dumps(data, sort_keys=True))
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
