from enum import StrEnum
from typing import ClassVar, TypeAlias

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field, JsonValue

JsonObject: TypeAlias = dict[str, JsonValue]


class SidecarErrorCode(StrEnum):
    RATE_LIMITED = "rate_limited"
    BLOCKED = "blocked"
    SCHEMA_CHANGED = "schema_changed"
    EMPTY_RESPONSE = "empty_response"
    INVALID_HOST = "invalid_host"
    NETWORK = "network"
    PARSE_FAILED = "parse_failed"


class SidecarError(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    code: SidecarErrorCode
    message: str


ERROR_RESPONSES: dict[int | str, dict[str, type["SidecarError"]]] = {
    400: {"model": SidecarError},
    403: {"model": SidecarError},
    422: {"model": SidecarError},
    429: {"model": SidecarError},
    502: {"model": SidecarError},
}


def sidecar_http_error(
    status_code: int,
    code: SidecarErrorCode,
    message: str,
) -> HTTPException:
    return HTTPException(
        status_code=status_code,
        detail=SidecarError(code=code, message=message).model_dump(mode="json"),
    )


def sidecar_runtime_error(operation: str, error: Exception) -> HTTPException:
    message = str(error).lower()

    if "429" in message:
        return sidecar_http_error(
            429,
            SidecarErrorCode.RATE_LIMITED,
            f"sidecar {operation} was rate limited",
        )

    if "403" in message or "forbidden" in message or "blocked" in message:
        return sidecar_http_error(
            403,
            SidecarErrorCode.BLOCKED,
            f"sidecar {operation} was blocked",
        )

    if "empty" in message:
        return sidecar_http_error(
            422,
            SidecarErrorCode.EMPTY_RESPONSE,
            f"sidecar {operation} returned an empty response",
        )

    return sidecar_http_error(
        422,
        SidecarErrorCode.PARSE_FAILED,
        f"sidecar {operation} failed to parse the response",
    )


class FetchRequest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    provider: str
    config: JsonObject = Field(default_factory=dict)


class ScrapeRequest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    provider: str
    config: JsonObject = Field(default_factory=dict)


class FetchResponse(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    provider: str
    status: str
    records: list[JsonObject] = Field(default_factory=list)


class ScrapeResponse(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    provider: str
    status: str
    records: list[JsonObject] = Field(default_factory=list)


class DetailScrapeRequest(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    url: str
    vendor: str
    max_bytes: int | None = Field(default=None, gt=0)


class DetailScrapeResponse(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    vendor: str
    source_uri: str
    contributors: list[dict[str, str]] = Field(default_factory=list)
    isbn_13: str | None = None
    published_on: str | None = None
    cover: JsonObject = Field(default_factory=dict)
    description: str | None = None


class BookRecord(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    provider: str
    source_uri: str
    work: JsonObject = Field(
        default_factory=dict,
        description="Work metadata: title, subtitle, original_title, original_language_code, subjects",
    )
    edition: JsonObject = Field(
        default_factory=dict,
        description="Edition metadata: title, subtitle, format, published_on, isbn_13, language_code, page_count, dimensions",
    )
    contributors: list[dict[str, str]] = Field(
        default_factory=list,
        description="List of contributor dicts with name and role",
    )
    cover: JsonObject = Field(
        default_factory=dict,
        description="Cover metadata: source_url, rights_basis, attribution_text",
    )
    field_sources: JsonObject = Field(
        default_factory=dict,
        description="Provenance mapping per field",
    )
    raw: JsonObject = Field(default_factory=dict)
