# Hiraeth Worklog

## 2026-06-12 — T1 baseline and process setup

Scope: execute `.omo/plans/catalog-dedup-metadata-performance.md` for catalog de-duplication, richer sourced metadata, local cover caching, and fast public catalog loading.

Approved defaults:
- one public book entry per logical `Work`, with formats/ISBNs nested;
- display sourced descriptions/editorial praise and external publisher/source CTAs;
- cache/store covers locally for fast initial load;
- keep the app Phoenix + LiveView + Ash, with no React, JSON API, or Oban;
- run `agy` before substantial UI polish;
- commit after every tested milestone.

Dirty worktree boundary:
- This repository already had uncommitted catalog/dataset changes before this plan started.
- Baseline evidence: `.omo/evidence/task-1-baseline-git-status.txt`.
- Existing dirty files are treated as baseline context and must not be reverted casually.
- Each milestone must stage only intentional files for that milestone and must not stage `.omo/`, `.omx/`, or `artifacts/`.

Process rule:
1. Implement the milestone.
2. Run its listed tests/QA.
3. Save evidence under `.omo/evidence/...` and/or `artifacts/qa/...`.
4. Update this worklog with commands, result, evidence, and files.
5. Commit only after the milestone is tested.

T1 checks:
- `.gitignore` already excludes `.omo/`, `.omx/`, and `artifacts/`.
- Staged pre-existing changes were unstaged with `git restore --staged .` to avoid accidental inclusion in the T1 process commit.

T1 process commit: b7eca18586084865745447907e3509fb4ef3a923 — chore(process): establish catalog worklog discipline

## 2026-06-12 — Baseline consolidation before T2

Reason: T2's public catalog test file depended on broad real-publisher dataset changes that were already dirty before this plan started. To keep later milestone commits meaningful, the pre-existing real-catalog baseline was tested and committed before reapplying the T2-only RED contract.

Commands:
- `MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs test/hiraeth/real_catalog_importer_test.exs test/hiraeth/provenance_audit_test.exs test/hiraeth_web/live/public_catalog_live_test.exs --trace`

Result: pass — 26 tests, 0 failures.

Evidence:
- `.omo/evidence/baseline-real-catalog-pre-t2-tests.txt`

Files: real catalog dataset/import/provenance/public catalog baseline files already present in the dirty worktree.

Baseline consolidation commit: e4ff613 — Add real publisher catalog dataset

## 2026-06-12 — T2 RED grouping contract

Scope: add a failing public catalog contract for one logical book entry per work, using Deep Vellum's `Immigrant` paperback and ebook records.

Commands:
- `MIX_ENV=test mix test test/hiraeth_web/live/public_catalog_live_test.exs --trace`

Result: expected RED — 5 tests, 1 failure. The failure is the missing grouped read API `PublicCatalog.search_books/1`.

Evidence:
- `.omo/evidence/task-2-red-dedup-tests.txt`
- Independent verifier: Verifier the 56th confirmed the RED failure, nested format contract, exact identifier union, and duplicate ISBN coverage.

Files:
- `test/hiraeth_web/live/public_catalog_live_test.exs`

T2 commit: fe1e900 — test(catalog): specify work-centric public grouping

T2 finalized commit after amend: be89e4a — test(catalog): specify work-centric public grouping

## 2026-06-12 — T3 RED metadata/prose contract

Scope: add failing tests for sourced descriptions, editorial praise, storefront/source CTAs, provenance requirements, importer persistence, public detail display, and continued rejection of commerce/raw HTML/content dumps.

Commands:
- `MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs:60 --trace`
- `MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs:85 --trace`
- `MIX_ENV=test mix test test/hiraeth/real_catalog_dataset_test.exs:175 --trace`
- `MIX_ENV=test mix test test/hiraeth/real_catalog_importer_test.exs:116 --trace`
- `MIX_ENV=test mix test test/hiraeth_web/live/public_catalog_live_test.exs:136 --trace`

Result: expected RED — failures are current validator/importer/UI missing behavior.

Evidence:
- `.omo/evidence/task-3-red-metadata-tests.txt`
- Independent verifier: Verifier the 58th confirmed the T3-only RED evidence and scoped test coverage.

Files:
- `test/hiraeth/real_catalog_dataset_test.exs`
- `test/hiraeth/real_catalog_importer_test.exs`
- `test/hiraeth_web/live/public_catalog_live_test.exs`

T3 commit: 7abe353 — test(metadata): specify public prose and storefront display

T3 finalized commit after amend: caba940 — test(metadata): specify public prose and storefront display

## 2026-06-12 — T4 RED cover cache contract

Scope: add failing tests for public cached-cover eligibility, public cover URL projection, link-only fallback, takedown hiding of cached covers, and component preference for cached `public_url` over remote `source_url`.

Commands:
- `MIX_ENV=test mix test test/hiraeth/covers_resource_test.exs --trace`
- `MIX_ENV=test mix test test/hiraeth_web/live/public_catalog_live_test.exs:159 --trace`

Result: expected RED — failures are current cover policy/projection/component behavior.

Evidence:
- `.omo/evidence/task-4-red-cover-cache-tests.txt`
- Independent verifier: Verifier the 59th confirmed the T4 RED contract and scoped failures.

Files:
- `test/hiraeth/covers_resource_test.exs`
- `test/hiraeth_web/live/public_catalog_live_test.exs`

T4 commit: 83aa994 — test(covers): specify cached public cover preference

T4 finalized commit after amend: 52380b6 — test(covers): specify cached public cover preference

## 2026-06-12 — T5 RED performance/browser contract

Scope: add failing tests for fast grouped public reads, duplicate work-card prevention, browser QA cover cache warmup, no duplicate cards, local cover paths, no remote cover dependency, and curl timing budgets.

Commands:
- `MIX_ENV=test mix test test/hiraeth_web/public_catalog_performance_test.exs --trace`
- `MIX_ENV=test mix test test/hiraeth/browser_qa_contract_test.exs --trace`

Result: expected RED — failures are missing `PublicCatalog.search_books/1` and missing browser QA cache/performance checks.

Evidence:
- `.omo/evidence/task-5-red-performance-contract.txt`
- Independent verifier: Verifier the 60th confirmed the T5 RED contract and scoped failures.

Files:
- `test/hiraeth_web/public_catalog_performance_test.exs`
- `test/hiraeth/browser_qa_contract_test.exs`

T5 commit: f3b219e — test(perf): specify fast grouped catalog loading

T5 finalized commit after amend: 2c18d3f — test(perf): specify fast grouped catalog loading

## 2026-06-12 — T6 schema support for public prose metadata

Scope: add Ash/Postgres schema support for Work-level `description`, `storefront_url`, and structured `editorial_praise` metadata.

Commands:
- `mix ash.codegen t6_public_prose_metadata --check`
- `MIX_ENV=test mix ecto.drop --force`
- `MIX_ENV=test mix ecto.create`
- `MIX_ENV=test mix ash.setup`
- `MIX_ENV=test mix test test/hiraeth/catalog_resource_test.exs --trace`
- `mix compile --warnings-as-errors`
- `mix format --check-formatted`

Result: pass. Ash codegen was reconciled with an Ash-generated migration and Work snapshot.

Evidence:
- `.omo/evidence/task-6-current-evidence-manifest.txt`
- `.omo/evidence/task-6-ash-codegen-check.txt`
- `.omo/evidence/task-6-ash-setup.txt`
- `.omo/evidence/task-6-schema-tests.txt`
- `.omo/evidence/task-6-compile.txt`
- `.omo/evidence/task-6-format.txt`
- Independent verifier: Verifier the 62nd confirmed schema, migration, snapshot, and commands.

Files:
- `lib/hiraeth/catalog/work.ex`
- `priv/repo/migrations/20260612215553_t6_public_prose_metadata.exs`
- `priv/resource_snapshots/repo/works/20260612215554.json`
- `test/hiraeth/catalog_resource_test.exs`

T6 commit: 8c7ed41 — feat(metadata): add sourced public prose fields

T6 finalized commit after post-verification amend: c9a973c — feat(metadata): add sourced public prose fields.

## T7 — Sourced prose metadata validator/importer/fixtures

Implemented the T7 prose metadata import contract.

Changed:
- Validator now allows only canonical public prose fields (`description`, `synopsis`, `editorial_praise`, `storefront_url`) and requires source/license provenance before those fields can be displayed.
- Validator continues to reject commerce state, raw HTML/rendered content dumps, author bios, user reviews, unsupported prose keys, unsafe source hosts, and missing displayed values.
- Dataset atomization/schema/docs now cover prose curation metadata and mirror the validator's unsafe-field contract.
- Added short, curated official product-page prose snippets to the first available work records for Deep Vellum (`Immigrant`), Dalkey Archive (`The Tunnel`), and Archipelago Books (`Bob and Hilbert`); no raw HTML, author bios, commerce state, or user reviews were imported.
- Importer now writes `Work.description`, `Work.storefront_url`, `Work.editorial_praise`, and source-record raw payload prose fields; existing non-blank work metadata is not overwritten by another format row.
- SourceRecord remains immutable and checksum-versioned; re-import with changed fixture checksum creates new source records while updating missing work projections.

Evidence:
- `.omo/evidence/task-7-acceptance-final-after-review-fixes.txt` — 29 tests, 0 failures.
- `.omo/evidence/task-7-format-after-review-fixes.txt` — format check passed.
- `.omo/evidence/task-7-compile-after-review-fixes.txt` — compile with warnings-as-errors passed.
- `.omo/evidence/task-7-real-import-summary-clean-after-review-fixes.txt` — clean seed imported 150 editions/source records.
- `.omo/evidence/task-7-provenance-summary-clean-after-review-fixes.txt` — missing provenance, invalid covers, long copied text all empty.
- `.omo/evidence/task-7-fixture-prose-summary.txt` — every publisher fixture has curated prose coverage.

Reviewer loop:
- First independent verifier returned `needs-fix` for schema parity, fixture prose evidence, and stale T7 evidence claim.
- Fixed all three: schema parity/additionalProperties, real sourced prose snippets in tracked fixtures, and replaced stale `.omo/evidence/task-7-done-claim.json`.

T7 commit: pending

T7 reviewer fix: added a malformed-input regression proving raw HTML inside canonical prose (`description`) is rejected, then expanded the validator's HTML marker detection. Evidence:
- `.omo/evidence/task-7-red-raw-html-prose.txt` — failed before validator fix.
- `.omo/evidence/task-7-raw-html-prose-fix.txt` — focused regression passed.
- `.omo/evidence/task-7-acceptance-final-after-raw-html-fix.txt` — 29 tests, 0 failures.
- `.omo/evidence/task-7-provenance-summary-clean-after-raw-html-fix.txt` — clean provenance gate passed.

T7 finalized commit: f2c69bd — feat(import): ingest sourced descriptions and praise.

## T8 — Local cover cache and public cover policy

Implemented local cover caching under `priv/static/covers/cache` and exposed it through Phoenix static paths (`covers`). Generated cached cover files are gitignored via `/priv/static/covers/cache/*`.

Changed:
- `Hiraeth.Covers.public_cover_asset?/1` now accepts both link-only remote covers and cache-allowed local covers when rights and paths are safe.
- Public cover maps include `public_url`, preferring `/covers/cache/...` for valid cached files and remote source URLs for link-only covers.
- Added deterministic cache path generation from source URL SHA-256 and extension.
- Added `Hiraeth.Covers.cache_public_covers!/1` and `mix hiraeth.cache_covers`, using `Req.get!/2` for downloads.
- Cache task skips already cached covers, refreshes stale DB paths whose files are missing, supports `--force`, and refuses unallowlisted/unsafe source URLs before fetch.
- Takedown and unsafe cached paths do not render local paths.

Evidence:
- `.omo/evidence/task-8-cover-cache-tests-final-after-review-fixes.txt` — 11 tests, 0 failures.
- `.omo/evidence/task-8-cover-component-test-final-after-review-fixes.txt` — cached public URL component test passed.
- `.omo/evidence/task-8-compile-final-after-review-fixes.txt` — compile passed.
- `.omo/evidence/task-8-format-final-after-review-fixes.txt` — format passed.
- `.omo/evidence/task-8-diff-check-final-after-review-fixes.txt` — diff whitespace check passed.
- `.omo/evidence/task-8-cache-task-help-final.txt` — Mix task help available.

T8 commit: pending

T8 finalized commit: 185a439 — feat(covers): serve cached public cover assets.

## T9 — Public catalog read indexes

Implemented public catalog query/index foundations using AshPostgres `custom_indexes` rather than a hand-written Ecto migration. Ash codegen generated `priv/repo/migrations/20260612223749_add_public_catalog_indexes.exs` plus resource snapshots, keeping resources and migrations consistent.

Indexes added:
- `editions`: `work_id`, `publisher_id`, `imprint_id`
- `identifiers`: `edition_id`, `value`
- `cover_assignments`: `edition_id`, `cover_asset_id`
- `contributions`: `work_id`, `edition_id`, `contributor_id`
- `series_memberships`: `work_id`, `series_id`
- `source_records`: `source_uri`, `(provider, source_type)`

Evidence:
- `.omo/evidence/task-9-red-index-migration-tests.txt` — index assertion failed before implementation.
- `.omo/evidence/task-9-ash-codegen.txt` — AshPostgres generated migration/snapshots.
- `.omo/evidence/task-9-ash-setup.txt` — test DB migrated.
- `.omo/evidence/task-9-index-migration-tests.txt` — 3 tests, 0 failures.
- `.omo/evidence/task-9-public-query-explain-specific.txt` — ISBN lookup uses `identifiers_public_catalog_value_index` and `cover_assignments_public_catalog_edition_id_index`.
- `.omo/evidence/task-9-format.txt`, `.omo/evidence/task-9-compile.txt` — format/compile gates passed.

T9 commit: pending

T9 finalized commit: 480d04c — perf(catalog): add public read indexes.

## T10 — Grouped public catalog read model

Implemented work-centric public book projections in `HiraethWeb.PublicCatalog` while preserving compatibility wrappers for existing edition pages.

Changed:
- Added `books/0`, `search_books/1`, and `book/1` grouped by canonical `work_id`.
- Book projections include work-level identity, publisher, contributors, series, descriptions, editorial praise, storefront URL, nested `formats`, identifier union, primary ISBN, cover projection including `public_url`, and source provenance list.
- Browse now uses grouped books, so duplicate formats render as one public card with nested format/ISBN data.
- Default page size increased to 24 for realistic browsing.
- Existing `editions/0`, `search_editions/1`, and `edition/1` remain as compatibility APIs for legacy/admin/detail surfaces until T11 route/UI conversion.

Evidence:
- `.omo/evidence/task-10-grouped-read-model-tests.txt` — grouped Immigrant UI/read-model test passed.
- `.omo/evidence/task-10-performance-search-tests.txt` — performance/search tests passed.
- `.omo/evidence/task-10-compile.txt`, `.omo/evidence/task-10-format.txt` — compile/format gates passed.

T10 commit: pending

T10 reviewer fixes:
- Full public catalog LiveView test now passes, not only the grouped line-filter test.
- Browse count was updated to grouped books (`79 books`, page 1 of 4 with page size 24).
- Edition detail minimally renders sourced `#book-description`, `#book-editorial-praise`, and `#book-storefront-cta` so T3/T10 evidence is not misleading before T11 UI polish.
- SourceRecord lookup is now scoped to projected ISBNs via SQL over `raw_payload->'edition'->>'isbn_13' = any($1::text[])` instead of reading all source records.
- Source projections now include `source_record_id` and `import_run_id` for grouped provenance traceability.

Review-fix evidence:
- `.omo/evidence/task-10-review-fixes-full-tests.txt` — 12 tests, 0 failures.
- `.omo/evidence/task-10-compile-after-review-fixes.txt`, `.omo/evidence/task-10-format-after-review-fixes.txt`, `.omo/evidence/task-10-diff-check-after-review-fixes.txt`.
