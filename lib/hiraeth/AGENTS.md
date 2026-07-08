# DOMAIN KNOWLEDGE BASE

## OVERVIEW
Ash domain layer for catalog data, ingestion, provenance, covers, real-publisher corpus, audit, search, and admin actors.

## STRUCTURE
| Area | Owns |
|---|---|
| `catalog/` + `catalog.ex` | work / edition / publisher / contributor graph |
| `sources/` + `sources.ex` | source records, ledger entries, curation overrides |
| `ingestion/` + `ingestion.ex` | provider runs, snapshots, candidates, events, phase pipeline |
| `imports/` + `imports.ex` | CSV/manual import staging and review |
| `real_catalog/` | deterministic dataset, policy, validation, importer |
| `covers/` + `covers.ex` | cover assets, assignments, cache safety |
| `audit/`, `provenance_audit.ex` | operational evidence and exports |
| `accounts/`, `search/` | admin actor helpers and read models |

## WHERE TO LOOK
| Task | File family |
|---|---|
| Add or change a resource | matching `*.ex` resource plus domain root `lib/hiraeth/<domain>.ex` |
| Provider ingestion behavior | `ingestion/operator_cli.ex`, `ingestion/phases/*.ex`, `ingestion/provider_*` |
| Source identity / allowlists | `real_catalog/source_identity.ex`, `real_catalog/source_policy.ex` |
| Real corpus import | `real_catalog/dataset.ex`, `validator.ex`, `importer.ex`, `source_artifacts.ex` |
| Cover cache decisions | `covers.ex`, `covers/cover_asset.ex`, `ingestion/cover_pipeline.ex` |
| Provenance audit | `provenance_audit.ex`, `sources/source_ledger_entry.ex` |

## CONVENTIONS
- Put identities, relationships, validations, policies, calculations, and business actions in Ash resources/domains.
- Preserve pipeline state: `ProviderRun` + `SourceSnapshot` + `RecordCandidate` + phase modules drive ingestion transitions.
- External source and cover fetches must pass central policy checks before network or cache writes.
- Imported records carry deterministic source identity, checksum/source lineage, field sources, ledger entries, and policy context.
- `SourceRecord` and snapshot artifacts are evidence. Prefer append/replay/quarantine over mutation.
- Catalog reads may be public; writes require trusted actors or ingestion/operator context.
- Oban is allowed only when retries/scheduling/cancellation/replay are genuinely needed.

## ANTI-PATTERNS
- Direct catalog mutation that bypasses Ash actions, ingestion phases, import workflows, or audit/provenance writes.
- Duplicating provider policy constants outside `RealCatalog.SourcePolicy`.
- Accepting mutable names/URLs as sole source identity when stable source IDs/checksums exist.
- Dropping `field_sources`, `source_uri`, `rights_basis`, checksums, or ledger records for convenience.
- Writing cover files outside the validated cache root or using unsanitized paths/symlink-following logic.
- Deleting a checked-in publisher/provider corpus or manifest because a refresh is empty; mark blocked/gap instead.
