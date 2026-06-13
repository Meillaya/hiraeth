# Provenance and Cover Policy

Hiraeth stores source evidence separately from canonical catalog records. Source records are immutable evidence, curation overrides are explicit reviewer decisions, and source ledger rows make displayed fields auditable.

## Metadata provenance

- Every public displayed field should have a source record, provider, source URI, source type, and license or rights basis.
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

## Oban deferral

No Oban in v1. If imports exceed synchronous limits or need retries/scheduling, add Oban in a future plan with idempotent jobs, provenance-preserving retry semantics, audit events, and clear failure/replay controls.
