# REAL PUBLISHER CORPUS KNOWLEDGE BASE

## OVERVIEW
Checked-in production corpus for the full 23-provider publisher set: one `<slug>.json` dataset per publisher plus `schema.json` and the authority/artifacts/coverage manifests. Sibling `priv/catalog_sources/provider_manifests/` is the policy slice that gates ingestion; this directory is the complete corpus, and `README.md` carries the operator narrative (gates, source URLs, rights assumptions, record counts).

## STRUCTURE
| File | Role |
|---|---|
| `<slug>.json` (23) | Publisher datasets: and_other_stories, archipelago_books, astra_house, a_strange_object, coffee_house_press, dalkey_archive, deep_vellum, fitzcarraldo_editions, fum_destampa, historical_materialism, la_reunion, mcnally_editions, new_directions, nyrb, phoneme_media, pushkin_press, seagull_books, semiotexte, seven_stories_press, tilted_axis_press, transit_books, unnamed_press, wakefield_press |
| `schema.json` | JSON Schema draft 2020-12 contract every dataset must satisfy |
| `source_authority_manifest.json` | TRUE registry: 23 `providers[]` entries plus global policies |
| `source_artifacts_manifest.json` | GENERATED artifact ledger; regenerate, never hand-edit |
| `source_coverage_report.json` | GENERATED coverage/gap report; regenerate, never hand-edit |
| `README.md` | Operator narrative; counts and per-provider source URLs live here |

## WHERE TO LOOK
| Task | Location |
|---|---|
| Add or amend a publisher dataset | `<slug>.json` here; update `source_authority_manifest.json` BEFORE adding/replacing records, and for gated providers keep the lockstep trio with the sibling manifest and `lib/hiraeth/real_catalog/source_policy.ex` |
| Required record fields | `schema.json`: required `source_uri`, `source_product_id`, `publisher`, `work`, `edition`, `contributors`, `displayed_fields`, `curation`, `field_sources`; optional `cover`/`no_cover_reason`/`cover_fallback_reason`, `description`, `synopsis`, `storefront_url`, `editorial_praise`, `review_links` |
| Registry/permission status | `source_authority_manifest.json`: per-provider `status`, `allowed_source_types`, `allowed_source_urls`, `allowed_source_hosts`, `allowed_cover_hosts`, `allowed_purchase_link_hosts`, `blocked_modes`, `source_corpus_boundary`, `required_evidence`; top-level `global_blocked_modes` (incl. `fabricated_metadata`, `invented_purchase_links`), `network_policy`, `review_policy`, `isbn_enrichment_policy`, `completeness_boundary` |
| Regenerate artifact/coverage manifests | `mix hiraeth.real_catalog.source_artifacts` (`Hiraeth.RealCatalog.SourceArtifacts.write_manifest!`) and `mix hiraeth.real_catalog.coverage_report` (`Hiraeth.RealCatalog.CoverageReport.write!`); never by hand |
| Loader semantics | `lib/hiraeth/real_catalog/dataset.ex` |
| Validation gate | `lib/hiraeth/real_catalog/validator.ex` |

## CONVENTIONS
- Dataset JSON shape: top-level `{provider, retrieved_at, license_note, provider_permissions, records[]}`; `provider_permissions` carries `provider`, `source_urls`, `source_hosts`, `cover_hosts`, `permission_basis`.
- `Hiraeth.RealCatalog.Dataset` does runtime `File.read` + `Jason.decode`, computes a sha256 `file_checksum` on every load, and atomizes keys against a known-key allowlist; `@non_dataset_files` excludes `schema.json`, the manifests, and `README.md` from loading.
- Downstream consumers: `RealCatalog.Importer.seed!/seed_provider!`, `RealCatalog.Validator.validate_datasets` (pre-seed gate), `ProviderRecordNormalizer` via `Dataset.normalize`, and `priv/repo/seeds.exs` → `Hiraeth.RealCatalogFixtures.seed!`.
- `mix hiraeth.review_scrape` and `mix hiraeth.apply_scrape` write into this directory; treat their output as governed corpus changes.
- Authority manifest entries are updated before record changes; tests treat the manifest as source of truth for provider availability.
- Record counts drift; see `README.md` for current totals instead of quoting numbers here.

## ANTI-PATTERNS
- Deleting or overwriting a dataset or authority record without explicit publisher-removal authorization.
- Hand-editing `source_artifacts_manifest.json` or `source_coverage_report.json`; both are generator output.
- Fabricating missing fields; gaps stay explicit (`no_cover_reason`, missing purchase links stay missing).
- Treating this directory as staging scratch; staging lives in the transient `priv/catalog_sources/staged/`.
- Reusing files across this directory and `test/support/fixtures`; the corpus is production evidence, not test data.
- Breaking load determinism; `Dataset` sha256 checksums feed import provenance, so rewrites must stay byte-stable and intentional.
