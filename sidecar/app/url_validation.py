"""Shared sidecar URL allowlist validation for outbound provider requests."""

import ipaddress
import socket
from typing import Final
from urllib.parse import ParseResult, urlparse

from app.models import JsonObject, SidecarErrorCode, sidecar_http_error

_LOCALHOST_NAMES: Final = {"localhost", "localhost.localdomain"}
_NUMERIC_IPV4_HOST_CHARS: Final = frozenset("0123456789abcdefABCDEFxX.")


def validate_url_against_source_hosts(
    url: str, *, field_name: str, config: JsonObject
) -> ParseResult:
    """Validate an outbound URL against the manifest source host allowlist."""
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            f"{field_name} must be HTTPS",
        )
    if parsed.username or parsed.password:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            f"{field_name} must not include userinfo",
        )
    if not parsed.hostname:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            f"{field_name} must include a host",
        )
    normalized_host = normalize_host(parsed.hostname)
    if private_host(normalized_host):
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            f"{field_name} host must not be private, loopback, link-local, or unspecified",
        )

    source_hosts = allowed_source_hosts(config)
    if normalized_host not in source_hosts:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            f"{field_name} host must be listed in source_hosts",
        )

    return parsed


def validate_start_urls_against_source_hosts(config: JsonObject) -> None:
    """Validate generic scrape start URLs against explicit source hosts."""
    start_urls = config.get("start_urls")
    if not isinstance(start_urls, list) or start_urls == []:
        raise sidecar_http_error(
            422,
            SidecarErrorCode.INVALID_HOST,
            "config.start_urls must include at least one allowed scrape URL",
        )

    for start_url in start_urls:
        if not isinstance(start_url, str) or start_url.strip() == "":
            raise sidecar_http_error(
                422,
                SidecarErrorCode.INVALID_HOST,
                "config.start_urls values must be non-empty URLs",
            )
        validate_url_against_source_hosts(
            start_url,
            field_name="config.start_urls",
            config=config,
        )


def allowed_source_hosts(config: JsonObject) -> set[str]:
    """Return normalized explicit source hosts from a sidecar config."""
    source_hosts = config.get("source_hosts")
    if not isinstance(source_hosts, list):
        return set()

    return {
        normalize_host(host)
        for host in source_hosts
        if isinstance(host, str)
        and normalize_host(host) != ""
        and not private_host(normalize_host(host))
    }


def normalize_host(host: str) -> str:
    """Normalize URL hostnames before policy comparison."""
    return host.strip().lower().rstrip(".")


def private_host(host: str) -> bool:
    """Return true for localhost, private, loopback, link-local, or unspecified IP hosts."""
    normalized = normalize_host(host)
    if normalized in _LOCALHOST_NAMES:
        return True

    parsed_address = _parsed_ip_address(normalized)
    if parsed_address is None:
        return False

    return (
        parsed_address.is_private
        or parsed_address.is_loopback
        or parsed_address.is_link_local
        or parsed_address.is_unspecified
    )


def _parsed_ip_address(
    host: str,
) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        pass

    if not _could_be_legacy_ipv4(host):
        return None

    try:
        return ipaddress.IPv4Address(socket.inet_aton(host))
    except OSError:
        return None


def _could_be_legacy_ipv4(host: str) -> bool:
    return host != "" and all(
        character in _NUMERIC_IPV4_HOST_CHARS for character in host
    )
