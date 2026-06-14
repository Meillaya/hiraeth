# Provenance and Cover Policy

Hiraeth stores source evidence separately from canonical catalog records. Source records are immutable evidence, curation overrides are explicit reviewer decisions, and source ledger rows make displayed fields auditable.

## Metadata provenance

- Every public displayed field should have a source record, provider, source URI, source type, and license or rights basis. Rich fields use field-level provenance in `field_sources` so descriptions, storefront links, original-language metadata, subjects, page counts, dimensions, ISBNs, and formats can be audited independently.
- `make audit-provenance` exports `artifacts/qa/provenance/source-ledger.csv` and fails on missing provenance, missing source ledger entries, invalid public cover records, and long copied-text risk signals.
- These checks are completeness/risk checks only. They do not make legal conclusions.

## Cover lifecycle

- v1 is link-only by default unless a checked-in dataset or provider policy explicitly
  records `rights_basis: "local_cache_permitted"` and `cache_policy: "cache_allowed"`.
- Public covers require source URL, provider, rights basis, attribution text/link when required, and a non-hidden takedown state.
- Cached cover files require explicit cache rights. Without that basis, render the source URL only when link-only display is allowed, or the typographic fallback when the public-cover gate fails.
- Takedown-hidden cover assignments must not render publicly, and takedown events should appear in audit exports.

## Current pilot dataset cover decision

The real-publisher pilot dataset under `priv/catalog_sources/real_publishers/`
is intentionally marked cacheable for this prototype catalog run. That decision
supersedes the earlier link-only planning default for these checked-in records
only. The implementation still keeps source URLs, provider names, attribution,
source records, local cache paths, thumbnail paths, and takedown controls
auditable.

These provenance checks are product/audit safeguards, not legal conclusions.
Treat this as a legal review required before production boundary.
Before production/commercial use, expansion to additional publishers or
bookstores, monetized cover display, or bulk jacket-copy/description imports,
perform a separate source-permission review and update the provider policy
records accordingly.

## New Directions fixture gate

New Directions (`new_directions_official_site`) is the fourth checked-in
provider fixture. Its gate allows factual
source references under `https://www.ndbooks.com/books/`, permission/contact
documentation under `https://www.ndbooks.com/permissions/` and
`https://www.ndbooks.com/about/contact/`, source host `www.ndbooks.com`, and
observed cover host `cdn.sanity.io`.

This gate does not grant local cover-cache rights. New Directions records use
explicit no-cover fallbacks and covers remain
`link_only_until_explicit_cache_permission` until a later provider policy records
explicit cache permission and provenance. The cover resolver and cache task also
reject accidental New Directions link-only/cache attempts before explicit cache
permission, so public pages render typographic fallbacks instead of remote images. The gate also excludes raw HTML,
jacket-copy dumps, author bios, reviews, prices, inventory, and storefront or
account data. It is an engineering safeguard and not legal advice.

The checked-in source policy currently marks New Directions as the only
expansion provider slug. Its provider-permission projection is intended to be
mirrored in the deterministic JSON fixture, so source URLs, source hosts,
cover hosts, excluded content, takedown contact, cover-cache policy, and the
not-legal-advice note remain machine-checkable before import.

## Oban deferral

No Oban in v1. If imports exceed synchronous limits or need retries/scheduling, add Oban in a future plan with idempotent jobs, provenance-preserving retry semantics, audit events, and clear failure/replay controls.
