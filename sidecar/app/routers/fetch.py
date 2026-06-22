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
