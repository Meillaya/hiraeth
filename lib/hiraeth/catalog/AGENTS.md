# CATALOG DOMAIN KNOWLEDGE BASE

## OVERVIEW
Ash catalog domain owning the curated work / edition / publisher / contributor graph and its public read projection. Reads are public, writes are gated by the catalog writer actor. Cover, source, and ingestion relationships are owned by their own domains; this file documents only catalog-local rules.

## STRUCTURE
| Path | Role |
|---|---|
| `catalog.ex` | domain root, resource registry |
| `catalog/publisher.ex` | `Hiraeth.Catalog.Publisher` (root publishing house) |
| `catalog/imprint.ex` | `Hiraeth.Catalog.Imprint` (sub-label, scoped to publisher) |
| `catalog/work.ex` | `Hiraeth.Catalog.Work` (abstract creative work) |
| `catalog/edition.ex` | `Hiraeth.Catalog.Edition` (concrete published edition) |
| `catalog/contributor.ex` | `Hiraeth.Catalog.Contributor` (person or org) |
| `catalog/contribution.ex` | `Hiraeth.Catalog.Contribution` (contributor slot on a work or edition) |
| `catalog/identifier.ex` | `Hiraeth.Catalog.Identifier` (ISBN and friends, edition-scoped) |
| `catalog/series.ex` | `Hiraeth.Catalog.Series` (named grouping of works) |
| `catalog/series_membership.ex` | `Hiraeth.Catalog.SeriesMembership` (work slot inside a series) |
| `catalog/public_projection.ex` + `catalog/public_projection/` | typed public read boundary: `Book`, `Format`, `Contributor`, `Cover`, `Source`, `Access` |
| `catalog/edition/nested_catalog_edges.ex` | nested-edge helper invoked from `Edition.create_with_catalog_edges` `after_action` |

## WHERE TO LOOK
| Task | File |
|---|---|
| Add or change a resource | matching `lib/hiraeth/catalog/<resource>.ex` and the domain root |
| Composite identities and index naming | every `*.ex` under `catalog/` (declarations are inline) |
| Public read shape | `catalog/public_projection.ex` and `catalog/public_projection/*.ex` |
| Composite create with contributor / identifier / cover | `catalog/edition.ex` `create_with_catalog_edges` action and `catalog/edition/nested_catalog_edges.ex` |
| Structural-shape gate | `test/hiraeth/catalog/public_projection_contract_test.exs` |
| CRUD suite | `test/hiraeth/catalog_resource_test.exs` |

## CONVENTIONS
- `Work.original_language_code` and `Edition.language_code` must match `^[a-z]{3}$` (lowercase ISO 639-3); surface violations via `Ash.Changeset` errors, never coerce or normalize silently.
- Custom Postgres indexes that back the public catalog query path use the naming `<table>_public_catalog_<col>_index` (for example `editions_public_catalog_work_id_index`, `contributions_public_catalog_edition_id_index`, `series_memberships_public_catalog_work_id_index`); declare them in `postgres do ... custom_indexes do ... end` so migrations stay in lockstep with the resources.
- Composite identities anchor catalog uniqueness: `Imprint` uses `unique_publisher_slug` over `[:publisher_id, :slug]`, `Contribution` uses `unique_contribution_slot` over `[:contributor_id, :role, :work_id, :edition_id]`, `SeriesMembership` uses `unique_series_work` over `[:series_id, :work_id]`. `Identifier` uses `unique_identifier` over `[:identifier_type, :value]`. Plain slugs use `unique_slug` on the owning resource.
- Authorization pattern: reads are always authorized (`authorize_if always()`); writes (`create`, `update`, `destroy`) require an actor carrying `catalog_write?: true` via `authorize_if actor_attribute_equals(:catalog_write?, true)`. No other write path exists.
- `Edition.create_with_catalog_edges` is the single public write entry point that fans out to contributor, identifier, and cover assignment. Its `after_action` hook calls `Hiraeth.Catalog.Edition.NestedCatalogEdges.apply!/3`, which performs nested `Ash.create!` calls with `authorize?: false` because the outer action was already authorized with the catalog writer actor; re-authorizing inside `after_action` against a possibly-nil actor would break legitimate nested writes.
- Public browser reads must route through `Hiraeth.Catalog.PublicProjection` (and its `public_projection/` subdirectory structs). Never serialize raw Ash records, Ash result structs, sidecar payloads, or SQL rows into public views.

## ANTI-PATTERNS
- Bypassing the `create_with_catalog_edges` action with manual `Contributor`, `Contribution`, `Identifier`, `CoverAsset`, or `CoverAssignment` writes from outside the authorized outer action.
- Re-enabling authorization on nested `Ash.create!` calls inside `NestedCatalogEdges`; the outer `after_action` is the authorization boundary.
- Coercing language codes, slugifying them, or storing empty strings when validation fails; reject the changeset instead.
- Renaming custom indexes away from `<table>_public_catalog_<col>_index` or dropping them; the public catalog query plan depends on them.
- Serializing Ash or SQL structures straight into LiveViews, templates, or JSON payloads instead of going through `PublicProjection`.
- Granting catalog writes to anonymous actors or bypassing the `catalog_write?` flag via direct Repo calls.
- Treating `Cover`, `Source`, or `SourceRecord` relationships as catalog-owned writes; those belong to the Covers and Sources domains and their own authorization rules.