import ipaddress
from typing import Any
from urllib.parse import urlparse

from fastapi import APIRouter, HTTPException

from app.models import FetchRequest, FetchResponse
from app.adapters import shopify, squarespace, woocommerce, wordpress

router = APIRouter(prefix="/fetch", tags=["fetch"])

ADAPTERS = {
    "shopify": shopify.fetch,
    "woocommerce": woocommerce.fetch,
    "squarespace": squarespace.fetch,
    "wordpress": wordpress.fetch,
}


@router.post("/")
async def fetch_catalog(request: FetchRequest) -> FetchResponse:
    api_type = request.config.get("api", {}).get("type")
    if not api_type:
        raise HTTPException(status_code=400, detail="Missing config.api.type")

    adapter = ADAPTERS.get(api_type)
    if not adapter:
        raise HTTPException(status_code=400, detail=f"Unsupported api.type: {api_type}")

    _validate_api_endpoint(request.config)

    try:
        records = await adapter({**request.config, "provider": request.provider})
        return FetchResponse(
            provider=request.provider,
            status="success",
            records=records,
        )
    except Exception as e:
        return FetchResponse(
            provider=request.provider,
            status=f"error: {str(e)}",
            records=[],
        )


def _validate_api_endpoint(config: dict[str, Any]) -> None:
    api = config.get("api", {})
    endpoint = api.get("endpoint")
    if not isinstance(endpoint, str) or endpoint.strip() == "":
        raise HTTPException(status_code=400, detail="Missing config.api.endpoint")

    parsed = urlparse(endpoint)
    if parsed.scheme != "https":
        raise HTTPException(status_code=400, detail="config.api.endpoint must be HTTPS")
    if parsed.username or parsed.password:
        raise HTTPException(status_code=400, detail="config.api.endpoint must not include userinfo")
    if not parsed.hostname:
        raise HTTPException(status_code=400, detail="config.api.endpoint must include a host")
    if _private_host(parsed.hostname):
        raise HTTPException(
            status_code=400,
            detail="config.api.endpoint host must not be private, loopback, or link-local",
        )

    source_hosts = config.get("source_hosts")
    if not isinstance(source_hosts, list) or parsed.hostname not in {str(host) for host in source_hosts}:
        raise HTTPException(
            status_code=400,
            detail="config.api.endpoint host must be listed in source_hosts",
        )


def _private_host(host: str) -> bool:
    if host.lower() in {"localhost", "localhost.localdomain"}:
        return True

    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False

    return address.is_private or address.is_loopback or address.is_link_local or address.is_unspecified
