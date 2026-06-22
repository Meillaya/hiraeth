from pydantic import BaseModel, Field
from typing import Any


class FetchRequest(BaseModel):
    provider: str
    config: dict[str, Any] = Field(default_factory=dict)


class ScrapeRequest(BaseModel):
    provider: str
    config: dict[str, Any] = Field(default_factory=dict)


class FetchResponse(BaseModel):
    provider: str
    status: str
    records: list[dict[str, Any]] = Field(default_factory=list)


class ScrapeResponse(BaseModel):
    provider: str
    status: str
    records: list[dict[str, Any]] = Field(default_factory=list)


class BookRecord(BaseModel):
    provider: str
    source_uri: str
    work: dict[str, Any] = Field(
        default_factory=dict,
        description="Work metadata: title, subtitle, original_title, original_language_code, subjects",
    )
    edition: dict[str, Any] = Field(
        default_factory=dict,
        description="Edition metadata: title, subtitle, format, published_on, isbn_13, language_code, page_count, dimensions",
    )
    contributors: list[dict[str, str]] = Field(
        default_factory=list,
        description="List of contributor dicts with name and role",
    )
    cover: dict[str, Any] = Field(
        default_factory=dict,
        description="Cover metadata: source_url, rights_basis, attribution_text",
    )
    field_sources: dict[str, Any] = Field(
        default_factory=dict,
        description="Provenance mapping per field",
    )
