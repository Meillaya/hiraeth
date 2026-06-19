# Provenance and Cover Policy

Hiraeth stores source evidence separately from canonical catalog records. Source records are immutable evidence, curation overrides are explicit reviewer decisions, and source ledger rows make displayed fields auditable.

## Metadata provenance

- Every public displayed field should have a source record, provider, source URI, source type, and license or rights basis. Rich fields use field-level provenance in `field_sources` so descriptions, storefront links, original-language metadata, subjects, page counts, dimensions, ISBNs, and formats can be audited independently.
- `make audit-provenance` exports `artifacts/qa/provenance/source-ledger.csv` and fails on missing provenance, missing source ledger entries, invalid public cover records, and long copied-text risk signals.
- These checks are completeness/risk checks only. They do not make legal conclusions.


## Full-catalog source authority

Full-catalog expansion is governed by `priv/catalog_sources/real_publishers/source_authority_manifest.json`. The manifest intentionally defines completeness as the approved source corpus rather than fabricated universal publisher history. For this refresh, the operator explicitly authorized bounded public HTML extraction, official APIs/sitemaps/pages, and third-party ISBN/cover enrichment. Blocked modes are now unsafe/unbounded or non-factual modes: fabricated metadata, invented purchase links, user reviews, raw copied review prose, account/cart/checkout data, and production database writes.

Execution must keep normal tests deterministic: live network retrieval belongs in bounded local tooling with source allowlists, rate limits, max-byte caps, checksums, retrieval timestamps, and recorded artifacts. Public UI still renders covers only from local `/covers/cache/...` URLs.

Release-facing completeness must be worded precisely: Hiraeth has loaded every record in the approved checked-in source corpus for the current seventeen providers. Gaps against universal historical backlists, unavailable non-HTML source exports, missing cover URLs, missing purchase links, missing review links, and missing/pre-ISBN identifiers remain explicit unresolved gap states in the coverage report and UI.

## Cover lifecycle

- Public HTML must never render remote cover URLs. A visible cover must resolve to a local static URL under `/covers/cache/...`.
- A public cover asset requires a source URL, provider, rights basis, allowlisted HTTPS cover host, attribution text/link when required, visible takedown state, `cache_policy: "cache_allowed"`, `rights_basis: "local_cache_permitted"`, and a validated cached file under `priv/static/covers/cache`.
- Permission-request or draft-request metadata is not a display blocker by itself. Provenance, official-source allowlists, local cache safety, attribution, takedown/removal handling, and auditability remain mandatory.
- link-only, missing, uncached, hidden, unsafe, or ineligible covers render the designed typographic fallback instead of a remote image.
- Takedown-hidden cover assignments must not render publicly, and takedown events should appear in audit exports.

## Current production corpus cover decision

The real-publisher corpus under `priv/catalog_sources/real_publishers/` is intentionally cacheable for providers with checked-in source-backed cover URLs. The implementation keeps source URLs, provider names, attribution, source records, local cache paths, thumbnail paths, and takedown controls auditable while rendering only local cache URLs.

These provenance checks are product/audit safeguards, not legal conclusions. A legal review required before production applies to commercial expansion, monetized cover display, or bulk jacket-copy/description imports; update provider policy records with the source model and provenance evidence.

## New Directions fixture gate

New Directions (`new_directions_official_site`) is an active checked-in provider fixture. Its gate allows factual source references under `https://www.ndbooks.com/books/`, contact surfaces under `https://www.ndbooks.com/permissions/` and `https://www.ndbooks.com/about/contact/`, source host `www.ndbooks.com`, and observed cover host `cdn.sanity.io`.

The provider gate records `cover_cache_policy: "cache_allowed"`: pending permission/draft-request state is not a blocker. The checked-in New Directions corpus currently contains 2,389 records and source-backed cover URLs for all records. Public display still requires an allowlisted HTTPS cover source, local cache validation, attribution, and visible takedown state. The gate excludes raw HTML dumps, author bios, user reviews, prices, inventory, storefront/account data, and unsupported long prose.

## Transit Books fixture gate

Transit Books (`transit_books_official_site`) is an active checked-in provider sourced from official books/catalog pages under `https://www.transitbooks.org/books`, `https://www.transitbooks.org/catalogs`, and related official paths. The allowed source host is `www.transitbooks.org`.

The provider gate records `cover_cache_policy: "cache_allowed"` with allowlisted Squarespace cover hosts. The checked-in Transit corpus currently contains 66 records and source-backed cover URLs for all records. Transit exclusions include raw HTML dumps, author bios, user reviews, prices, inventory, cart/checkout/account data, unattributed cover images, and unsupported long prose.

## Oban deferral

No Oban in v1. If imports exceed synchronous limits or need retries/scheduling, add Oban in a future plan with idempotent jobs, provenance-preserving retry semantics, audit events, and clear failure/replay controls.
