# Provenance and Cover Policy

Hiraeth stores source evidence separately from canonical catalog records. Source records are immutable evidence, curation overrides are explicit reviewer decisions, and source ledger rows make displayed fields auditable.

## Metadata provenance

- Every public displayed field should have a source record, provider, source URI, source type, and license or rights basis.
- `make audit-provenance` exports `artifacts/qa/provenance/source-ledger.csv` and fails on missing provenance, missing source ledger entries, invalid public cover records, and long copied-text risk signals.
- These checks are completeness/risk checks only. They do not make legal conclusions.

## Cover lifecycle

- v1 is link-only by default.
- Public covers require source URL, provider, rights basis, attribution text/link when required, and a non-hidden takedown state.
- Cached cover files require explicit cache rights. Without that basis, render the typographic fallback.
- Takedown-hidden cover assignments must not render publicly, and takedown events should appear in audit exports.

legal review required before production use if Hiraeth caches covers, monetizes cover display, expands third-party cover providers, or imports real jacket copy/descriptions at scale.

## Oban deferral

No Oban in v1. If imports exceed synchronous limits or need retries/scheduling, add Oban in a future plan with idempotent jobs, provenance-preserving retry semantics, audit events, and clear failure/replay controls.
