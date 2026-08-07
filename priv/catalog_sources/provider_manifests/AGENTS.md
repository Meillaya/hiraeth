# PROVIDER MANIFESTS KNOWLEDGE BASE

## OVERVIEW
Checked-in policy manifests for the 11 provider integrations that route through `priv/catalog_sources/provider_manifests/`. Each JSON file is a source-of-truth input that declares the fetch/scrape surface, permission and contact URLs, source/cover host allowlists, takedown path, and cover-cache posture for one provider. These manifests are operator-authored inputs, not generator output. They are distinct from `priv/resource_snapshots/repo/`, which holds Ash generator state and replay evidence.

## STRUCTURE
| File | Provider slug |
|---|---|
| `and_other_stories_official_store.json` | and_other_stories |
| `astra_house_official_store.json` | astra_house |
| `charco_press_official_store.json` | charco_press |
| `coffee_house_press_official_store.json` | coffee_house_press |
| `deep_vellum_official_store.json` | deep_vellum_official_store |
| `open_letter_books_official_store.json` | open_letter_books |
| `pushkin_press_us_official_store.json` | pushkin_press_us_official_store |
| `sandorf_passage_official_store.json` | sandorf_passage |
| `seagull_books_official_store.json` | seagull_books |
| `two_lines_press_official_store.json` | two_lines_press |
| `wakefield_press_official_store.json` | wakefield_press |

Sibling `priv/catalog_sources/real_publishers/` carries the checked-in publisher corpus and its `source_authority_manifest.json`. See `priv/catalog_sources/real_publishers/README.md` for the operator narrative covering the broader 23-provider corpus; this directory is the policy slice for the 11 providers whose manifests gate ingestion.

## WHERE TO LOOK
| Task | File |
|---|---|
| Add or amend one provider's policy JSON | matching `*_official_store.json` here, plus lockstep edits in `priv/catalog_sources/real_publishers/source_authority_manifest.json` and `lib/hiraeth/real_catalog/source_policy.ex` |
| Verify which gate fields the runtime expects | `@required_gate_fields` in `lib/hiraeth/real_catalog/source_policy.ex` |
| Confirm a provider is policy-ready | `Hiraeth.RealCatalog.SourcePolicy.provider_policy_ready?/1` and `provider_gate_ready?/1` |
| Trace a host or path allowlist decision | `cover_hosts/2`, `source_hosts/2`, `source_path_prefixes/1` in `source_policy.ex`, all of which union the manifest host/path data with hardcoded defaults |

## CONVENTIONS
- Every manifest must populate the gate fields enforced by `Hiraeth.RealCatalog.SourcePolicy.@required_gate_fields`: `provider`, `name`, `source_urls`, `permission_urls`, `contact_urls`, `source_hosts`, `cover_hosts`, `permission_basis`, `provenance_notes`, `cover_cache_policy`, `excluded_content`, `takedown_contact` (plus `not_legal_advice?` for the new-style gate providers).
- Manifest edits travel in lockstep with `priv/catalog_sources/real_publishers/source_authority_manifest.json` (authority record for the same provider) and `lib/hiraeth/real_catalog/source_policy.ex` (host/path allowlists and `provider_gates` map). Shipping one without the other breaks `provider_policy_ready?/1` and the host/path union helpers.
- `provider`, `source_urls`, `source_hosts`, and `cover_hosts` must agree across the three files; manifest values feed the runtime `ManifestProvider` entry, while the policy module maps may add defaults that the gate check tolerates only via the union helpers.
- Follow the per-file schema already used by `deep_vellum_official_store.json` (`source_mode`, `cadence_hours`, `spider`, `api`, `rate_limit`, `expected_record_count`) when extending a manifest; the `Hiraeth.Ingestion.ProviderManifest` loader is the contract that consumes these blocks.
- `cadence_hours` (positive integer, default 24) declares the minimum interval between scheduled ingestion runs for one provider. It flows manifest -> `Hiraeth.Ingestion.ProviderManifest` struct -> `ProviderBackfill.Inventory` -> `ProviderBackfill.apply!/0` -> `provider_sources.cadence_hours`. The manifest JSON is the single source of truth: `mix hiraeth.providers.backfill` overwrites every `provider_sources` row from the manifests on every run, so DB-only edits to `cadence_hours` (or any other backfilled column) get clobbered on the next backfill - change the manifest and re-run backfill instead.
- Host strings stay lowercase, scheme stays `https`, and contact/permission/takedown URLs stay reachable from the provider's public surface.

## ANTI-PATTERNS
- Dropping the `provider`, `source_urls`, `source_hosts`, or `cover_hosts` agreement between this directory, `real_publishers/source_authority_manifest.json`, and `source_policy.ex`.
- Adding a manifest entry whose gate fields fail `provider_gate_ready?/1` (missing `permission_urls`, empty `excluded_content`, blank `takedown_contact`, or `cover_cache_policy` policy/host mismatch).
- Weakening `excluded_content`, `permission_basis`, or `takedown_contact` to green-light an integration that has not actually documented its permission path.
- Hardcoding provider hosts or purchase paths in `lib/hiraeth` while the live manifest points at a different host, splitting the policy of truth across code and data.
- Treating `priv/catalog_sources/provider_manifests/*.json` as staging scratch or copy-pasting it into per-provider runbook docs; this directory is the canonical machine-readable record.
- Editing `cadence_hours` (or any backfilled provider field) directly in the `provider_sources` table and expecting it to stick; the next `mix hiraeth.providers.backfill` overwrites DB state from the manifests.
