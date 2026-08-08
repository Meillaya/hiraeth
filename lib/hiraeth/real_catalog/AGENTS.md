# REAL CATALOG KNOWLEDGE BASE

## OVERVIEW
Plain module namespace, not an Ash domain, for the real-publisher corpus: dataset loading, provider permission policy, pre-seed validation, and idempotent Ash writes. Invoked from seeds, Mix tasks, and ingestion phases; parent knowledge bases govern domain ownership and shared rules.

## STRUCTURE
| File | Owns |
|---|---|
| `dataset.ex` | loader for `priv/catalog_sources/real_publishers`; sha256 `file_checksum` per load; atomizes keys against a known-key allowlist; loads `source_authority_manifest.json` |
| `source_policy.ex` | provider permission source of truth (686 lines). L6-208 constants (`@cover_hosts`, `@source_hosts`, `@source_path_prefixes`, `@source_pdf_path_prefixes`, `@required_gate_fields`, `@provider_gates`); L210-355 public predicates/gates; L371-682 private manifest resolution + URI/path/source-handle matching |
| `validator.ex` | pre-seed findings gate (783 lines). `validate_dir`/`validate_datasets` return `{:ok, summary}` or `{:error, findings}` |
| `importer.ex` | idempotent trusted Ash writer (1555 lines). `seed!/1` whole corpus; `seed_provider!/3` single provider inside `Ash.transact` with 30-min timeout and stale pruning |
| `source_identity.ex` | stable source id precedence: product id > source_uri > isbn |
| `isbn.ex` | ISBN-13 normalization + check-digit validation |
| `slug.ex` | slugify helper (`@moduledoc false`) |
| `source_fetcher.ex` | bounded Req fetch guard for approved source artifacts; test seam, no live network in normal tests |
| `source_artifacts.ex` | writes `source_artifacts_manifest.json` |
| `coverage_report.ex` | writes `source_coverage_report.json` |

## WHERE TO LOOK
| Task | Location / order |
|---|---|
| Corpus seed call order | `Dataset.load_dir` → `Validator.validate_datasets` (consults `SourcePolicy`) → `Importer.seed!` |
| Ingestion call order | `phases/fetch_snapshot` (`SourcePolicy.load_provider_manifest`) → `phases/validate_candidates` (`Validator`) → `phases/apply_candidates` (`Dataset.normalize` + `Importer.seed_provider!`) → `phases/audit_run` |
| Seed entrypoint | `priv/repo/seeds.exs` → `Hiraeth.RealCatalogFixtures.seed!` |
| Staged scrape lane | `mix hiraeth.scrape`, `mix hiraeth.review_scrape` (Validator); `mix hiraeth.apply_scrape` (`seed_provider!`) |
| Validator check scope | blanks, ISBN-13, source_uri/format/storefront vs `SourcePolicy`, cover host + provenance, `field_sources` presence + approved types, prose/praise/review-link provenance, copy risk (commerce-state keys, raw/executable HTML), provider mismatch, cross-dataset duplicates, manifest provider/record-count reconciliation |
| Policy consumers outside namespace | `covers.ex`, `public_catalog.ex`, `provider_ingestion_worker`, `ingestion/cover_pipeline`, `ingestion/provider_backfill` |
| Manifest + dataset schema | `priv/catalog_sources/provider_manifests/AGENTS.md`, `priv/catalog_sources/real_publishers/AGENTS.md` |

## CONVENTIONS
- `SourcePolicy` is the single home for provider policy constants. It unions manifest host/path data with hardcoded defaults via `cover_hosts/2`, `source_hosts/2`, `source_path_prefixes/1`.
- Lockstep for gated providers: `source_policy.ex` constants + `priv/catalog_sources/provider_manifests/<slug>.json` + `real_publishers/source_authority_manifest.json` change together.
- Dataset dir resolves at runtime via `Application.app_dir/2` (`Dataset.default_dir/0`) so releases locate the corpus; manifests load via `:code.priv_dir` with a process-dictionary test override.
- Importer writes are trusted (`authorize?: false`), so callers must pass datasets through `Validator` first. Any finding blocks seeding.
- Preserve dataset determinism; per-file checksums feed import provenance.
- Per-table bulk import order (FK order): publishers → imprints/contributors/series → works → editions → identifiers → contributions → series_memberships → cover_assets → cover_assignments → source_records, each an `Ash.bulk_create` upsert (`upsert?: true`, per-resource `upsert_identity`, minimal `upsert_fields {:replace, identity_keys}` — never `:replace_all`); `import_runs` (find-or-create on provider+status) and new-only `source_ledger_entries` are diffed Elixir-side. Per-row `Ash.update!`/`destroy!` runs only for actual sync/prune diffs: `sync_work_metadata!` (guarded by `source_safe_work_update?`), `sync_edition_metadata!`, cover-asset sync, contribution-position sync, stale contribution/cover-assignment prunes, and `prune_stale_source_records!`.

## ANTI-PATTERNS
- Duplicating provider policy constants outside `SourcePolicy`.
- Bypassing the validator gate or calling the importer with unvalidated datasets.
- Fabricating metadata to fill dataset gaps.
- Hand-editing generated manifests (`source_artifacts_manifest.json`, `source_coverage_report.json`).
- Weakening gate fields (`excluded_content`, `permission_basis`, `takedown_contact`) to green-light a provider.
