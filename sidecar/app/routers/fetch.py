from fastapi import APIRouter

from app.adapters import shopify, squarespace, woocommerce, wordpress
from app.models import (
    ERROR_RESPONSES,
    FetchRequest,
    FetchResponse,
    JsonObject,
    SidecarErrorCode,
    sidecar_http_error,
    sidecar_runtime_error,
)
from app.url_validation import validate_url_against_source_hosts

router = APIRouter(prefix="/fetch", tags=["fetch"])

ADAPTERS = {
    "shopify": shopify.fetch,
    "woocommerce": woocommerce.fetch,
    "squarespace": squarespace.fetch,
    "wordpress": wordpress.fetch,
}


@router.post("/", responses=ERROR_RESPONSES)
async def fetch_catalog(request: FetchRequest) -> FetchResponse:
    api_type = _api_type(request.config)
    if not api_type:
        raise sidecar_http_error(
            400,
            SidecarErrorCode.SCHEMA_CHANGED,
            "Missing config.api.type",
        )

    adapter = ADAPTERS.get(api_type)
    if not adapter:
        raise sidecar_http_error(
            400,
            SidecarErrorCode.SCHEMA_CHANGED,
            f"Unsupported api.type: {api_type}",
        )

    _validate_api_endpoint(request.config)

    try:
        records = await adapter({**request.config, "provider": request.provider})
        return FetchResponse(
            provider=request.provider,
            status="success",
            records=records,
        )
    except KeyError as error:
        raise sidecar_http_error(
            502,
            SidecarErrorCode.SCHEMA_CHANGED,
            "sidecar fetch response schema changed",
        ) from error
    except OSError as error:
        raise sidecar_http_error(
            502,
            SidecarErrorCode.NETWORK,
            "sidecar fetch network failure",
        ) from error
    except Exception as error:
        raise sidecar_runtime_error("fetch", error) from error


def _validate_api_endpoint(config: JsonObject) -> None:
    api = config.get("api", {})
    endpoint = api.get("endpoint") if isinstance(api, dict) else None
    if not isinstance(endpoint, str) or endpoint.strip() == "":
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "Missing config.api.endpoint",
        )

    validate_url_against_source_hosts(
        endpoint,
        field_name="config.api.endpoint",
        config=config,
    )


def _api_type(config: JsonObject) -> str | None:
    api = config.get("api")
    if not isinstance(api, dict):
        return None

    api_type = api.get("type")
    if isinstance(api_type, str):
        return api_type

    return None
