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

T7 commit: f2c69bd — feat(import): ingest sourced descriptions and praise

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

T8 commit: 185a439 — feat(covers): serve cached public cover assets

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

T9 commit: 480d04c — perf(catalog): add public read indexes

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

T10 commit: e2c7029 — feat(catalog): group public books by work

T10 reviewer fixes:
- Full public catalog LiveView test now passes, not only the grouped line-filter test.
- Browse count was updated to grouped books (`79 books`, page 1 of 4 with page size 24).
- Edition detail minimally renders sourced `#book-description`, `#book-editorial-praise`, and `#book-storefront-cta` so T3/T10 evidence is not misleading before T11 UI polish.
- SourceRecord lookup is now scoped to projected ISBNs via SQL over `raw_payload->'edition'->>'isbn_13' = any($1::text[])` instead of reading all source records.
- Source projections now include `source_record_id` and `import_run_id` for grouped provenance traceability.

Review-fix evidence:
- `.omo/evidence/task-10-review-fixes-full-tests.txt` — 12 tests, 0 failures.
- `.omo/evidence/task-10-compile-after-review-fixes.txt`, `.omo/evidence/task-10-format-after-review-fixes.txt`, `.omo/evidence/task-10-diff-check-after-review-fixes.txt`.

T10 finalized commit: e2c7029 — feat(catalog): group public books by work.

## T11 — Grouped book LiveView routes and detail UI

Implemented the T11 public book UI conversion.

Changed:
- Added canonical `/books/:slug` `BookLive` detail pages with description, editorial praise, source storefront CTA, source provenance, cover attribution, cached-cover preference, and nested format/ISBN rows.
- Kept `/editions/:slug` compatibility by navigating known edition slugs to their containing `/books/:slug` page; unknown edition slugs still render the explicit not-found state.
- Updated browse, search, and home surfaces to use grouped `PublicCatalog.books/0` and `PublicCatalog.search_books/1` projections instead of edition rows.
- Book cards now link to `/books/:slug`, show short descriptions when sourced, and keep nested format/ISBN chips visible.
- Replaced stale public “volume” labels with book/catalog language across the public UI.
- Updated related route-shell, UI-state, and admin-cover tests for grouped book routes and edition redirect compatibility.
- Expanded source lookup compatibility for existing demo fixtures that store ISBN under `raw_payload.identifier.isbn_13`.

Evidence:
- `.omo/evidence/task-11-book-live-tests.txt` — 7 public catalog LiveView tests, 0 failures.
- `.omo/evidence/task-11-related-tests-final.txt` — public catalog/read-model/performance/search tests, 12 tests, 0 failures.
- `.omo/evidence/task-11-live-tests-final.txt` — public catalog, route shell, UI state, and admin cover LiveView tests, 20 tests, 0 failures.
- `.omo/evidence/task-11-book-live-dom.html` — rendered book detail DOM containing cached cover path, editorial praise, CTA, formats/ISBNs, and provenance.
- `.omo/evidence/task-11-dom-proof.txt` — exact cached-cover/editorial-praise/CTA markers.
- `.omo/evidence/task-11-volume-label-scan.txt` — no stale public Volume labels.
- `.omo/evidence/task-11-compile-final.txt`, `.omo/evidence/task-11-format-final.txt`, `.omo/evidence/task-11-diff-check-final.txt` — compile/format/diff-check gates passed.
- Independent verifier: Verifier the 73rd confirmed T11 after review fixes.

T11 finalized commit: 3432a83 — feat(web): render grouped book catalog pages.

## T12 — agy-guided grouped catalog UI polish

Implemented a quiet editorial archive / marginalia-cabinet visual pass over the grouped catalog UI.

Changed:
- Ran `agy` in print mode before UI changes; the CLI exited successfully but produced empty stdout in this environment, so the prompt and fallback in-repo design brief are captured in evidence.
- Polished grouped book cards with tactile hover states, focus-visible rings, description excerpts, and compact format/ISBN chips.
- Polished book detail with an editorial dark reading panel, stronger source CTA, readable sourced prose, bordered format rows, improved metadata/provenance panels, and responsive no-overflow behavior.
- Polished browse/search containers, filter rail, search table, empty states, pagination focus states, and mobile readability.
- Fixed all visual QA contrast findings on the book detail page, including headings, micro-labels, metadata labels, and the back-link.

Evidence:
- `.omo/evidence/task-12-agy-ui-design.txt` — agy invocation log and fallback design brief.
- `.omo/evidence/task-12-ui-tests.txt` — 12 LiveView UI tests, 0 failures.
- `.omo/evidence/task-12-compile.txt`, `.omo/evidence/task-12-format.txt`, `.omo/evidence/task-12-diff-check.txt` — compile/format/diff-check gates passed.
- `artifacts/qa/task-12-ui/{desktop,tablet,mobile}-{browse,book}.png` — browser screenshots.
- `.omo/evidence/task-12-responsive-overflow.json` and `.omo/evidence/task-12-responsive-overflow-after-contrast.json` — no horizontal overflow across desktop/tablet/mobile.
- `.omo/evidence/task-12-visual-diff-desktop-browse.json`, `.omo/evidence/task-12-visual-diff-mobile-book.json` — alpha/diff script evidence.
- Visual QA pass B: Hubble the 73rd passed visual fidelity/CJK precision; no blocking findings.
- Visual QA pass A: multiple strict contrast revisions were fixed; Plato the 73rd passed final contrast verification.

Cleanup:
- Stopped the temporary Phoenix server on port 4023 after screenshot capture.

T12 finalized commit: 03ffac3 — style(web): polish grouped book catalog UI.


## T13 — Browser QA cache, grouping, metadata, and performance evidence

Completed grouped-catalog browser QA updates for book-detail routes, local cover cache, and first-paint performance.

Changed:
- Updated browser QA from edition detail capture to `/books/deep-vellum-immigrant`.
- Added cache warmup via `mix hiraeth.cache_covers` before browser captures.
- Added curl timing evidence for `/browse`, `/browse?q=Immigrant`, and `/books/deep-vellum-immigrant`; latest local run was 86ms, 86ms, and 91ms total/TTFB respectively.
- Added assertions for one card per book slug, local cached cover paths, no remote Immigrant image `src` dependency, sourced prose/CTA/source provenance presence, and decoded cached image rendering with `naturalWidth > 0`.
- Added deterministic Browser QA cover seeding with a valid local PNG fixture and hid competing Immigrant cover assignments so takedown fallback is observable.
- Kept existing authenticated admin/import/review/cover governance checks intact, now using the canonical book route for public cover checks.

Evidence:
- `.omo/evidence/task-13-browser-qa.txt` — full Chromium browser QA passed with `test_browser=pass`.
- `.omo/evidence/task-13-curl-timing.txt` — all three routes under the 300ms TTFB / 800ms total budget.
- `.omo/evidence/task-13-browser-qa-contract.txt` — browser QA contract test passed.
- `.omo/evidence/task-13-artifact-inspection.json` — raw artifact parser confirmed no duplicate book slugs, local decoded cover, prose/CTA, and fallback after takedown.
- `artifacts/qa/browser-dedup-metadata-cache/image-decode.json` — Chrome confirmed cached cover `complete=true`, `naturalWidth=1`, `naturalHeight=1`.
- `artifacts/qa/browser-dedup-metadata-cache/admin-authenticated.json` and `network-errors.json` — admin flow and network checks passed.
- `.omo/evidence/task-13-mix-compile.txt`, `.omo/evidence/task-13-format-check.txt`, `.omo/evidence/task-13-git-diff-check.txt` — compile/format/diff-check gates passed.
- Independent verifier: Verifier the 76th confirmed T13 after prose/CTA and image decode fixes.

Cleanup:
- Browser QA trap stopped Phoenix and docker compose resources; `.omo/evidence/task-13-docker-cleanup.txt` captured final cleanup.
- Removed ignored `priv/static/covers/cache/browser-qa-immigrant.*` QA files after evidence capture; seeding recreates the PNG deterministically.

T13 finalized commit: 05fbfb2 — test(browser): verify cached grouped catalog UX


## T14 — Full verification and clean milestone boundary

Completed final milestone verification for the grouped catalog, metadata display, local cover cache, and browser QA performance work.

Verification run:
- Reset the test database before focused verification after a stale-state debug finding.
- Focused suite: `24 tests, 0 failures` across public catalog LiveView, grouped search/performance, cover resources, and browser QA contract.
- `mix precommit`: `123 tests, 0 failures` after compile, unused-deps, formatting, and full test suite.
- `make test-browser`: full Chromium browser QA passed with `test_browser=pass`; timings were `/browse` 97ms, `/browse?q=Immigrant` 87ms, `/books/deep-vellum-immigrant` 104ms.
- Final git status evidence was clean before the T14 worklog commit.

Debug note:
- The first focused-suite attempt failed because stale persisted test database rows from previous verification made cover-cache tests see an unrelated `fixture-debug-immigrant` cache candidate.
- Confirmed by `.omo/evidence/task-14-debug-cover-assets-before-reset.txt`; reset/migrate toggled `CoversResourceTest` from 4 failures to `11 tests, 0 failures`.
- No production code change was needed for that failure; the T14 verification process now records the reset-first discipline.

Evidence:
- `.omo/evidence/task-14-focused-suite.txt`
- `.omo/evidence/task-14-mix-precommit.txt`
- `.omo/evidence/task-14-make-test-browser.txt`
- `.omo/evidence/task-14-debug-journal.md`
- `.omo/evidence/task-14-final-git-status-after-debug-cleanup.txt`
- `.omo/evidence/task-14-git-log.txt`

Milestone commits:
- `05fbfb2` — test(browser): verify cached grouped catalog UX
- `9065cc3` — chore(process): record final T13 commit reference
- `7680818` — chore(qa): record catalog metadata performance verification

Final status for T14: pass; unresolved T14 risks: none beyond normal local browser-QA timing variance (latest timings were within budget).


## Final verification remediation — F1 plan compliance fixes

Addressed the initial F1 compliance audit revisions before final approval.

Changed:
- Cover cache task now uses bounded `Task.async_stream` fetch planning with configurable concurrency and timeout.
- Cover cache failures are skipped and reported by default; `--strict` / `strict?: true` raises on failures.
- Mix task exposes `--timeout`, `--concurrency`, and `--strict`, and prints failed count.
- Public browse/search now use query/page-specific work-id SQL selection and only load editions for selected work ids, rather than using broad full-catalog loading as the browse foundation.
- Added regression tests for skipped fetch failures, strict failure mode, and timeout handling.
- Removed an unused browser QA script variable flagged in code review.

Evidence:
- `.omo/evidence/final-f1-fixes-tests.txt` — cover/public catalog focused suite passed, 21 tests, 0 failures.
- `.omo/evidence/final-f1-fixes-public-live.txt` — public catalog LiveView focused rerun passed, 7 tests, 0 failures.

Remediation finalized commit: e4ce65f — fix(catalog): close final compliance gaps


## Final verification remediation — search pagination and SQL correctness

Addressed the second F1/F2 audit revisions before rerunning final verification.

Changed:
- Search LiveView now uses `PublicCatalog.book_page/3` for the initial `/search` render and real-time search events instead of loading the full catalog stream.
- Public catalog SQL now escapes `%`, `_`, and `!` for text `LIKE` searches, so wildcard characters are treated as literal malformed input.
- Work-id and count queries now require matching source provenance before a work contributes to public pagination/counts, aligning SQL totals with the source-attached projections rendered later.
- Blank browse/search work-id selection has a minimal source-safe SQL path to keep full-catalog page reads under the performance budget.
- Added regressions for literal `%` / `_` search handling and for excluding source-less editions from public pagination.

Evidence:
- `.omo/evidence/final-search-sql-correctness-tests.txt` — focused public catalog LiveView/performance suite passed, 9 tests, 0 failures.
- `.omo/evidence/final-after-search-fixes-precommit.txt` — `MIX_ENV=test mix precommit` passed, 126 tests, 0 failures.
- `.omo/evidence/final-after-search-fixes-browser.txt` — `make test-browser` passed with `test_browser=pass`; timings were `/browse` 97ms, `/browse?q=Immigrant` 99ms, `/books/deep-vellum-immigrant` 85ms.
- `.omo/evidence/final-after-search-fixes-docker-cleanup.txt` — docker/browser QA cleanup receipt.

Remediation commit: 32b585d — fix(catalog): page search with source-safe SQL


## Final verification wave — plan complete

Final verification wave completed after the search/source-safe SQL remediation.

Results:
- F1 plan compliance audit: APPROVE; evidence `.omo/evidence/final-plan-compliance.md`.
- F2 code quality review: APPROVE; evidence `.omo/evidence/final-code-quality.md`.
- F3 real manual QA: APPROVE; evidence `.omo/evidence/final-manual-qa.md` plus browser artifacts.
- F4 scope fidelity: APPROVE; evidence `.omo/evidence/final-scope-fidelity.md`.

Latest verification commands:
- `MIX_ENV=test mix test test/hiraeth_web/live/public_catalog_live_test.exs test/hiraeth_web/public_catalog_performance_test.exs --trace` — 9 tests, 0 failures.
- `MIX_ENV=test mix precommit` — 126 tests, 0 failures.
- `make test-browser` — `test_browser=pass`; `/browse`, `/browse?q=Immigrant`, and `/books/deep-vellum-immigrant` all under the 300ms/800ms budgets.

Final remediation/process commits:
- `32b585d` — fix(catalog): page search with source-safe SQL
- `33bad2a` — chore(process): record final search compliance fix


## Global review remediation — performance contract and cover-cache SSRF

Addressed blocking findings from the Global Review and Debugging Gate.

Changed:
- `PublicCatalog.books/0` and `search_books/1` now delegate to `book_page(..., 1).entries`, so compatibility helpers stay page-bounded and match the public page foundation.
- Added a regression assertion that the grouped public catalog performance helper returns no more than `PublicCatalog.page_size()` entries.
- Cover cache fetches now force `redirect: false` in `Req`, preventing allowlisted cover hosts from redirecting the server-side cache task to internal or non-allowlisted URLs.
- Cover cache root overrides are now constrained to `priv/static/covers/cache` or its subdirectories.
- Added regressions for redirect-following SSRF prevention and unsafe cache-root rejection.

Debug/root cause:
- Performance probe before fix showed `search_books("")` hydrating 79 entries and exceeding the 100ms helper budget while `book_page("", 1)` hydrated 24 entries in ~22–28ms.
- Post-fix probe showed `search_books("")` returning 24 entries with warm timings around 11–16ms.

Evidence:
- `.omo/evidence/final-performance-red-page-bound.txt` — failing-first performance evidence before the page-bound helper fix.
- `.omo/evidence/final-performance-debug-after.txt` and `.omo/evidence/final-performance-focused-after.txt` — performance and public LiveView focused suites passed after the fix.
- `.omo/evidence/final-security-cover-cache-ssrf-tests.txt` — cover cache SSRF/cache-root regression suite passed, 15 tests, 0 failures.
- `.omo/evidence/final-after-performance-security-focused.txt` — combined covers/performance/public LiveView focused suite passed, 24 tests, 0 failures.
- `.omo/evidence/final-after-performance-security-precommit.txt` — `MIX_ENV=test mix precommit` passed, 128 tests, 0 failures.
- `.omo/evidence/final-after-performance-security-browser.txt` — `make test-browser` passed with `test_browser=pass`; timings were `/browse` 81ms, `/browse?q=Immigrant` 96ms, `/books/deep-vellum-immigrant` 81ms.
- `.omo/evidence/final-performance-security-debug-journal.md` — hypothesis-driven debug journal and cleanup record.

Remediation commit: 682a972 — fix(catalog): close global review blockers

## Catalog performance optimization — Milestone 0/1 start

- Date: 2026-06-13
- Plan: `.omo/plans/catalog-performance-optimization.md`
- Baseline RED evidence: `.omo/evidence/m0-red-performance-contracts.txt`
  - New query-count contracts failed on current code: list paths 14 queries, detail/directory paths 13 queries against budgets of 8.
- Implemented initial read-path fix in `HiraethWeb.PublicCatalog`:
  - Replaced wide Ash relationship hydration for `editions_for_work_ids/1` and `editions/0` with a single SQL-backed projection query.
  - Preserved source provenance, cover policy filtering, contributor, series, description, editorial praise, storefront, and format grouping fields.
- Verification evidence:
  - `.omo/evidence/m1-compile-after-dead-code.txt` — `mix compile --warnings-as-errors` passed.
  - `.omo/evidence/m1-focused-performance-after-imported-at-fix.txt` — focused performance/LiveView/browser-contract suite: 15 tests, 0 failures.

## Catalog performance optimization — Milestone 2

- Date: 2026-06-13
- Replaced public publisher/series directory paths with summary/detail-specific SQL reads:
  - `publishers/0` and `series/0` now return summaries without running the full edition projection query.
  - `publisher/1` scopes edition projection to `where e.publisher_id = $1::uuid`.
  - `series_by_slug/1` scopes edition projection to the series work IDs.
  - `edition/1` resolves via the slug's work id instead of filtering `editions()`.
- Strengthened `Hiraeth.QueryCounting` to capture query SQL as well as query count.
- Added performance assertions that index paths do not hide a broad all-edition projection query and that detail paths use scoped edition projections.
- Verification evidence:
  - `.omo/evidence/m2-compile-after-cleanup.txt` — `mix compile --warnings-as-errors` passed.
  - `.omo/evidence/m2-performance-tests-scoped-queries-green-final.txt` — performance tests: 6 tests, 0 failures.
  - `.omo/evidence/m2-public-live-browser-contract-green.txt` — public LiveView/browser-contract focused suite: 9 tests, 0 failures.

## Catalog performance optimization — Milestone 3

- Date: 2026-06-13
- Added explicit public catalog search/index migration:
  - Source-record ISBN expression index for JSON ISBN provenance joins.
  - Trigram indexes for work/edition titles and subtitles, publisher names, contributor display names, series titles, and normalized identifier values.
- Updated migration contract test to require the new indexes.
- EXPLAIN evidence captured through `Hiraeth.Repo.query!/2` because `psql` is not installed in the container:
  - `.omo/evidence/m3-explain-source-by-isbn.txt` shows `Bitmap Index Scan on source_records_public_catalog_isbn_expr_index`.
  - `.omo/evidence/m3-explain-book-page-empty.txt`
  - `.omo/evidence/m3-explain-book-page-immigrant.txt`
  - `.omo/evidence/m3-explain-publisher-detail.txt`
- Verification evidence:
  - `.omo/evidence/m3-migration-test.txt` — migration index test: 3 tests, 0 failures.
  - `.omo/evidence/m3-focused-tests.txt` — migration + public catalog performance/LiveView/browser-contract suite: 18 tests, 0 failures.

## Catalog performance optimization — Milestone 4

- Date: 2026-06-13
- Improved cover rendering/perceived speed:
  - Cover images now render with explicit `loading`, `decoding="async"`, `fetchpriority`, and `width`/`height` attributes.
  - Card covers default to lazy loading; home spotlight and book detail covers opt into eager/high priority.
  - Browser QA now validates lazy/async/dimension attributes on cached cover DOM.
  - Browser QA screenshot coverage now includes `/browse?page=2` and `/search` to match timing coverage.
- Verification evidence:
  - `.omo/evidence/m4-compile.txt` — `mix compile --warnings-as-errors` passed.
  - `.omo/evidence/m4-focused-ui-tests.txt` — public LiveView/browser-contract focused suite: 9 tests, 0 failures.

## Catalog performance optimization — Milestone 5

- Date: 2026-06-13
- Added local cover derivatives and stricter cache behavior:
  - `cover_assets.thumbnail_file_path` is now part of the Ash resource, AshPostgres migration, and resource snapshot.
  - `cache_public_covers!/1` stores cached originals and bounded thumbnail derivatives under `priv/static/covers/cache`.
  - Thumbnail generation is wrapped by a timeout guard and the external `timeout` command before ImageMagick, so malformed or stuck derivative processing skips the thumbnail instead of hanging cache warmup.
  - Public catalog projections expose `thumbnail_url` only when the derivative path is safe and exists.
  - Card/list covers prefer thumbnails; hero/detail covers keep the full cached original.
  - Cached-cover purge/takedown clears both original and thumbnail paths.
- Updated real publisher dataset cover policy for this product run:
  - The explicit publisher fixture covers are now `cache_allowed` / `local_cache_permitted` with matching schema, validator, and README text.
  - Browser QA now fails if any captured public page emits a remote `<img src="http...">` after cache warmup.
- Debug/QA hardening:
  - Moved deterministic real-catalog fixture seeding to `setup_all` for the heavy LiveView/performance test modules to avoid repeated import work causing fresh-DB test timeouts.
  - Replaced a brittle browser QA stream-internal duplicate-card regex with a stable card/article link assertion.
- Verification evidence:
  - `.omo/evidence/m5-thumbnail-timeout-test.txt` — cover cache timeout regression: 17 tests, 0 failures.
  - `.omo/evidence/m5-focused-all-after-timeout-fix.txt` — focused covers/catalog/performance/dataset/importer/migration suite: 59 tests, 0 failures.
  - `.omo/evidence/m5-browser-qa-after-timeout-fix.txt` — `make test-browser` passed; all public route timings were under budget and `remote_image_dependencies=pass scope=all_captured_pages`.
  - `.omo/evidence/m5-debug-live-search-timeout-journal.md` — debug journal for fresh-DB LiveView timeout; setup fix reduced the isolated search test from ~69s to ~177ms.
  - `.omo/evidence/m5-ash-codegen-check-final.txt` — Ash codegen check passed after adding the thumbnail resource snapshot/migration.
- Verifier feedback:
  - Initial independent verifier found three blockers: unbounded ImageMagick, stale README rights text, and missing worklog.
  - This section plus the timeout fix and README correction address those blockers; follow-up independent verification is required before marking the plan checkbox complete.

Commit: 7c2f4fa — `perf(covers): serve optimized local cover derivatives`

## Catalog performance optimization — Milestone 6

- Date: 2026-06-13
- Decision: skipped the optional immutable public read-model cache.
- Reason: after the SQL read-path, index, LiveView rendering, and cover-derivative changes, current measured routes and public catalog read functions are already comfortably inside the plan budgets. Adding a cache now would add invalidation/takedown complexity without evidence of remaining projection overhead.
- Verification evidence:
  - `.omo/evidence/m6-performance-cache-skip-tests.txt` — public catalog performance suite: 6 tests, 0 failures.
  - `.omo/evidence/m6-cache-skip-decision.md` — browser route timings from the latest browser QA, with public routes under 300ms TTFB / 800ms total.

Commit: 1c53c91 — `chore(perf): record read-model cache skip`

## Catalog performance optimization — Milestone 7 final verification wave

- Date: 2026-06-13
- Final QA after cover/cache and mobile search fixes:
  - `mix format --check-formatted`, `mix compile --warnings-as-errors`, focused performance tests, and full `mix test` passed.
  - `make test-browser` and `STRICT_TIMING=1 make test-browser` passed with all public route timings under budget.
  - Browser QA now includes `mobile_search_overflow=pass` to prevent the mobile search table clipping regression found during visual QA.
  - `MIX_ENV=test mix precommit` passed with 136 tests, 0 failures.
- Visual QA:
  - Initial visual pass found mobile search overflow on a 390px viewport.
  - Fixed search rows to stack on mobile and added `scripts/responsive_overflow_check.mjs`.
  - Follow-up visual pass approved the refreshed mobile search screenshot and overflow JSON.
- Verification evidence:
  - `.omo/evidence/m7-full-mix-test-post-mobile-fix.txt`
  - `.omo/evidence/m7-browser-qa-strict-post-mobile-fix.txt`
  - `.omo/evidence/m7-precommit-post-mobile-fix.txt`
  - `.omo/evidence/m7-browser-qa-mobile-search-fix.txt`
  - `artifacts/qa/browser/mobile-search-overflow.json`

Commits:
- fcfe2aa — `fix(covers): allow cacheable covers before warmup`
- ce340a8 — `fix(ui): stack search results on mobile`
- 05db7ed — `chore(qa): record final performance verification`
- e08a1b9 — `chore(process): finalize verification worklog commit`
- Context-mining review found older cover-policy docs still stated link-only defaults without noting the superseding cacheable pilot decision. Updated `docs/provenance-cover-policy.md` and the earlier OMX dataset plan to document that the checked-in pilot dataset is cacheable for this prototype run while future providers remain link-only unless explicit cache rights are recorded.


## Catalog performance optimization — Milestone 7 review remediation

- Date: 2026-06-13
- Addressed independent security/code-quality review blockers found after the first final-verification pass:
  - Cacheable covers no longer render remote source URLs before a safe local cached file exists; provenance audit can still recognize explicit cache rights before warmup.
  - Cached cover paths now reject symlinked files/components under `priv/static/covers/cache` before public display.
  - `cache_public_covers!/1` backfills missing thumbnails from already cached originals, so migrated/previously cached rows receive card derivatives without refetching originals.
  - Real-catalog import now syncs provider, rights basis, attribution, and cache policy onto existing cover assets so old `link_only` rows upgrade idempotently when the validated dataset changes.
  - Responsive overflow QA now binds Chrome DevTools to loopback, rejects non-local targets by default, uses CDP/global timeouts, and waits for the expected page marker before probing overflow.
  - Component cover assertions now use LazyHTML selector/attribute checks.
- Verification evidence after remediation:
  - `.omo/evidence/m7-compile-post-review-fixes.txt` — compile with warnings as errors passed.
  - `.omo/evidence/m7-focused-post-review-fixes.txt` — focused covers/importer/provenance/LiveView/performance suite: 43 tests, 0 failures.
  - `.omo/evidence/m7-script-syntax-post-review-fixes.txt` — browser QA shell and responsive overflow script syntax checks passed.
  - `.omo/evidence/m7-full-mix-test-post-review-fixes.txt` — full suite: 138 tests, 0 failures.
  - `.omo/evidence/m7-browser-qa-strict-post-review-fixes.txt` — strict browser QA passed with all route timings under budget, no remote public image dependencies, thumbnail decode, and mobile overflow checks.
  - `.omo/evidence/m7-precommit-post-review-fixes.txt` — `MIX_ENV=test mix precommit`: 138 tests, 0 failures.

Commit: 61b857b — `fix(covers): secure cacheable cover display`

## Next roadmap — T0 provider gate

- Date: 2026-06-13
- Added a New Directions provider preflight gate before any dataset expansion work:
  - Provider slug: `new_directions_official_site`.
  - Official source page: `https://www.ndbooks.com/books/`.
  - Permission/contact pages: `https://www.ndbooks.com/permissions/` and `https://www.ndbooks.com/about/contact/`.
  - Allowed source host: `www.ndbooks.com`; observed public cover host: `cdn.sanity.io`.
  - New Directions covers remain `link_only_until_explicit_cache_permission`; this task does not authorize local cover caching or data import.
  - The gate excludes raw HTML, jacket-copy dumps, author bios, reviews/user reviews, prices, inventory, storefront/account, and cart/checkout data.
  - The gate is an engineering provenance safeguard and not legal advice.
- Verification evidence:
  - `.omo/evidence/task-0-red-provider-gate-test.txt` — RED provider gate test before `SourcePolicy.provider_gate!/1` and readiness checks existed.
  - `.omo/evidence/task-0-new-directions-*-page.html` — captured official source/permission/contact evidence for the preflight decision.

## Next roadmap — T1 role-aware contributors

- Date: 2026-06-13
- Added role-aware contributor projection/display for public discovery:
  - `PublicCatalog.book/1` and book pages now expose `authors`, `translators`, and `contributors_by_role` while preserving generic `contributor_names`.
  - Book detail, browse cards, search rows, cover fallbacks, and metadata tables now label authors separately from translators.
  - Existing `Contribution.role` remains the source of truth; no separate Author/Translator resources or `/authors`/`/translators` routes were added.
- Verification evidence:
  - `.omo/evidence/task-1-red-role-aware-contributors.txt` — RED tests for missing role-aware projection and UI labels.
  - `.omo/evidence/task-1-green-role-aware-contributors.txt` — focused public catalog/LiveView suite passed after implementation.
  - `.omo/evidence/task-1-role-aware-contributors-http.txt` — real HTTP route rendered `by Joaquín Zihuatanejo` and `translated by David Bowles`.
  - `.omo/evidence/task-1-search-regression.txt` — generic search resource regression passed.
  - `.omo/evidence/task-1-browser-qa-strict.txt` — strict browser QA passed after the public UI change.

## Next roadmap — T2 source-backed bibliographic fields

- Date: 2026-06-13
- Added persisted Ash/AshPostgres metadata fields for the approved ownership contract:
  - `Work.original_title`, `Work.original_language_code`, and `Work.subjects`.
  - `Edition.language_code`, `Edition.page_count`, `Edition.height_mm`, `Edition.width_mm`, and `Edition.depth_mm`.
  - Page count and dimensions are nullable but, when present, must be positive integers; dimensions are stored in millimetres.
- Generated AshPostgres migration and snapshots:
  - `priv/repo/migrations/20260613181658_add_source_backed_bibliographic_fields.exs`.
  - `priv/resource_snapshots/repo/editions/20260613181659.json`.
  - `priv/resource_snapshots/repo/works/20260613181700.json`.
- Verification evidence:
  - `.omo/evidence/task-2-red-resource-metadata.txt` — RED resource tests before the Ash fields/actions existed.
  - `.omo/evidence/task-2-green-resource-metadata.txt` — catalog resource tests passed after migration and implementation.
  - `.omo/evidence/task-2-ash-codegen-check.txt` — AshPostgres migration/snapshot check passed.
  - `.omo/evidence/task-2-rich-metadata-tmux.txt` — tmux QA channel passed catalog resource tests with trace output.
  - `.omo/evidence/task-2-domain-topology.txt` — Work/Edition topology regression passed.

### T2 review remediation

- Independent verification found missing coverage for updates and `Edition.create_with_catalog_edges`, plus a real nested-edge authorization failure.
- Added tests for:
  - `Work.update` preserving `original_title`, `original_language_code`, and `subjects`.
  - `Edition.update` preserving language, page count, and millimetre dimensions.
  - `Edition.create_with_catalog_edges` accepting and persisting the new metadata fields.
  - invalid physical metadata on update.
- Fixed nested catalog edge writes so the already-authorized outer admin action performs its transactional implementation writes without re-authorizing against a missing after-action actor.
- Verification evidence:
  - `.omo/evidence/task-2-red-review-remediation.txt` — reproduced `create_with_catalog_edges` forbidden failure.
  - `.omo/evidence/task-2-green-review-remediation.txt` — catalog resource tests passed after the nested-edge fix.
  - `.omo/evidence/task-2-focused-post-review-fix.txt` — resource and topology tests passed after remediation.

### T2 language-code remediation

- Independent verification found `original_language_code` and `language_code` accepted non-ISO values.
- Added nullable ISO 639-3 validation for both fields using lowercase three-letter codes.
- Added malformed create, update, and `create_with_catalog_edges` tests for invalid language metadata.
- Verification evidence:
  - `.omo/evidence/task-2-red-language-code-validation.txt` — reproduced invalid `english`/`en` acceptance.
  - `.omo/evidence/task-2-green-language-code-validation.txt` — catalog resource tests passed with validation in place.
  - `.omo/evidence/task-2-focused-post-language-fix.txt` — resource and topology tests passed after the language-code remediation.

## Next roadmap — T3 canonical dataset provenance schema

- Date: 2026-06-13
- Extended the tracked real-publisher JSON contract with machine-checkable provider permission metadata and per-displayed-field provenance:
  - Added top-level `provider_permissions` metadata for provider, source URLs/hosts, cover hosts/cache policy, permission basis, excluded content, takedown contact, and not-legal-advice note.
  - Added per-record `field_sources` entries for every field listed in `displayed_fields`.
  - Reserved rich source-backed metadata keys for original title/language, subjects, edition language, page count, and dimensions without importing external enrichment.
  - Kept `field_sources` field names as binary strings while atomizing only known structural keys, preventing unbounded atom creation from attacker-controlled field names.
- Validation now rejects missing provider permission metadata, missing/unsafe field-level provenance, provider/source mismatches, unsupported field source types, and the existing unsafe cover/prose/commerce/raw-content cases.
- Verification evidence:
  - `.omo/evidence/task-3-red-dataset-schema-a.txt` — RED dataset/schema contract before provider permissions and field provenance existed.
  - `.omo/evidence/task-3-green-dataset-schema.txt` — focused dataset tests passed after schema/validator updates.
  - `.omo/evidence/task-3-dataset-schema-tmux.txt` — tmux QA trace for the dataset suite: 25 tests, 0 failures.
  - `.omo/evidence/task-3-validator-cli.txt` — validator CLI returned `{:ok, ...}` for the tracked three-provider corpus.
  - `.omo/evidence/task-3-field-source-coverage.txt` — all 150 records have field-source coverage for displayed fields.

## Next roadmap — T4 New Directions provider policy scaffolding

- Date: 2026-06-13
- Added the machine-readable provider-policy scaffolding for the approved next expansion provider, New Directions:
  - `expansion_provider_slugs/0` returns exactly `new_directions_official_site` for this batch.
  - `provider_permission_metadata!/1` projects the gate into the future JSON `provider_permissions` shape.
  - `source_uri_allowed?/2`, `cover_uri_allowed?/2`, and `cover_cache_allowed?/1` provide deterministic host/cache checks without adding data import or live scraping.
  - New Directions covers remain link-only until explicit cache permission is recorded.
- Verification evidence:
  - `.omo/evidence/task-4-red-provider-policy.txt` — RED tests before policy projection and URL helpers existed.
  - `.omo/evidence/task-4-green-provider-policy.txt` — source policy tests passed after implementation.

## Next roadmap — T5 Postgres search/filter contract

- Date: 2026-06-13
- Added the public discovery filter contract on the bounded `HiraethWeb.PublicCatalog` Postgres read path:
  - `book_page/3` now accepts either the legacy text query or a filter map with `q`, `publisher`, `role`, `contributor`, `format`, `language`, `subject`, `series`, `year`, and `sort`.
  - Sort contract supports `title`, `newest`, `author`, and `recently_added`.
  - Browse query params now flow into `PublicCatalog.book_page/3`; full UI controls remain for the later LiveView filter task.
  - `Hiraeth.Search.Result` is explicitly marked non-public for browser discovery because its manual read hydrates editions before filtering.
- Verification evidence:
  - `.omo/evidence/task-5-red-filter-contracts.txt` — RED tests before filter maps and the non-public Ash search marker existed.
  - `.omo/evidence/task-5-focused-tests.txt` — focused PublicCatalog/search/LiveView suite passed.
  - `.omo/evidence/task-5-filter-contract-http.txt` — `/browse?publisher=deep-vellum&role=translator&format=paperback&sort=title` returned HTTP 200 and filtered Deep Vellum results.
  - `.omo/evidence/task-5-malformed-search.txt` — malformed `%` query with filters returned HTTP 200 and a safe empty state.
  - `.omo/evidence/task-5-format-check.txt`, `.omo/evidence/task-5-compile.txt`, and `.omo/evidence/task-5-diff-check.txt` — formatting, warning-free compile, and whitespace checks passed.

## Next roadmap — T6 migration/snapshot verification

- Date: 2026-06-13
- Verified the enriched metadata persistence layer added in commit `4bd6a73`:
  - `20260613181658_add_source_backed_bibliographic_fields.exs` migrates the approved work and edition fields.
  - Ash snapshots for `works` and `editions` are present and migration generation remains in sync.
  - A fresh test database reset migrated all schema files from scratch and seeded the real-publisher catalog.
- Verification evidence:
  - `.omo/evidence/task-6-migration-reset-tmux.txt` — `MIX_ENV=test mix ecto.reset` completed and applied the enriched metadata migration.
  - `.omo/evidence/task-6-ash-migration-test.txt` — migration topology/index tests passed.
  - `.omo/evidence/task-6-ash-codegen-check.txt` — AshPostgres migration check passed.
  - `.omo/evidence/task-6-compile.txt` — warning-free test compile passed.
  - `.omo/evidence/task-6-diff-check.txt` — whitespace diff check passed.

## Next roadmap — T7 enriched importer ingestion

- Date: 2026-06-13
- Extended deterministic JSON import so sourced rich metadata reaches Ash resources and immutable source records:
  - Work imports now preserve `original_title`, `original_language_code`, `subjects`, sourced prose, storefront URL, and editorial praise.
  - Edition imports now preserve `language_code`, `page_count`, and millimetre dimensions from the source fixture.
  - SourceRecord raw payloads now retain `provider_permissions` and per-field `field_sources` alongside rich work/edition values.
  - Existing nonblank curated work/edition metadata is preserved on reimport; newer checksum-versioned source records are still written for audit.
  - Update actions for Work/Edition are explicitly non-atomic because validation of unchanged language-code fields blocks Ash atomic update planning.
- Verification evidence:
  - `.omo/evidence/task-7-red-importer-enriched.txt` — RED importer suite before provider-permission/field-source fixture updates and enriched ingestion.
  - `.omo/evidence/task-7-importer-tmux.txt` — tmux importer suite passed: 6 tests, 0 failures.
  - `.omo/evidence/task-7-dev-seed.txt` — dev seed returned 150 editions, 150 identifiers, 150 source records, 150 cover assignments, and 3 import runs.
  - `.omo/evidence/task-7-validator-cli.txt` — tracked corpus validation returned `{:ok, ...}` with 150 records and no duplicate/copy/cover findings.
  - `.omo/evidence/task-7-format-check.txt`, `.omo/evidence/task-7-compile.txt`, `.omo/evidence/task-7-ash-codegen-check.txt`, and `.omo/evidence/task-7-diff-check.txt` — formatting, warning-free compile, migration check, and whitespace check passed.

### T7 provenance-gap remediation

- Independent verification found that non-displayed rich metadata could be imported without `field_sources` provenance.
- Added a RED importer regression proving an unsourced `work.original_language_code` was accepted, then hardened validation so every present rich metadata field requires field-level provenance even when the field is not listed in `displayed_fields`.
- Verification evidence:
  - `.omo/evidence/task-7-red-unsourced-rich-metadata.txt` — reproduced the unsourced rich metadata acceptance.
  - `.omo/evidence/task-7-green-unsourced-rich-metadata.txt` — importer and dataset tests passed after validation hardening.
  - `.omo/evidence/task-7-focused-post-review-fix.txt` — importer, dataset, and resource tests passed after remediation.

## Next roadmap — T8 bounded enriched public read model

- Date: 2026-06-14
- Extended the bounded `HiraethWeb.PublicCatalog` SQL projection so public book/detail/page reads expose sourced rich metadata without hydrating the full catalog:
  - Work fields: `original_title`, `original_language_code`, and `subjects`.
  - Edition/format fields: `language_code`, `page_count`, millimetre `height_mm`/`width_mm`/`depth_mm`, and a derived dimensions projection.
  - Source projection fields: per-field `field_sources` and provider-level `provider_permissions`.
- Preserved UUID-safe public IDs by keeping IDs normalized as display-safe strings in projection maps.
- Updated public LiveView projection assertions to compare format subsets so additional sourced fields do not break existing format contracts.
- Verification evidence:
  - `.omo/evidence/task-8-red-public-read-enriched-2.txt` — RED public catalog performance test before enriched projection keys existed.
  - `.omo/evidence/task-8-focused-tests.txt` and `.omo/evidence/task-8-focused-rerun-after-resume.txt` — focused PublicCatalog and LiveView tests passed: 20 tests, 0 failures.
  - `.omo/evidence/task-8-public-read-http.txt` — `/books/deep-vellum-immigrant` returned HTTP 200 with role-aware contributor and format/storefront data.
  - `.omo/evidence/task-8-publisher-browser.json` — headless Chromium rendered `/publishers/deep-vellum` with a screenshot artifact and no duplicate-card finding.
  - `.omo/evidence/task-8-format-check.txt`, `.omo/evidence/task-8-compile.txt`, `.omo/evidence/task-8-diff-check.txt`, and `.omo/evidence/task-8-diff-check-after-resume.txt` — formatting, warning-free compile, and whitespace checks passed.

### T8 source-less directory remediation

- Independent verification found source-less publishers/series could appear in directory/detail summaries even though book pagination excluded them.
- Added a RED regression for `PublicCatalog.publishers/0`, `PublicCatalog.publisher/1`, `PublicCatalog.series/0`, and `PublicCatalog.series_by_slug/1` using a source-less publisher, edition, and series.
- Tightened publisher and series summary SQL so directory rows require at least one edition with matching source-record provenance.
- Verification evidence:
  - `.omo/evidence/task-8-red-sourceless-directories.txt` — reproduced source-less publisher leakage.
  - `.omo/evidence/task-8-green-sourceless-directories.txt` — focused performance suite passed after SQL hardening.
  - `.omo/evidence/task-8-focused-post-review-fix.txt` — focused PublicCatalog and LiveView suite passed after remediation: 21 tests, 0 failures.
  - `.omo/evidence/task-8-public-read-http-post-review-fix.txt` and `.omo/evidence/task-8-publisher-browser-post-review-fix.json` — post-fix HTTP/browser QA remained green and did not expose the source-less test marker.

## Next roadmap — T9 indexed Postgres facet/sort read paths

- Date: 2026-06-14
- Added indexed public catalog facet coverage for the bounded Postgres read path:
  - New migration `priv/repo/migrations/20260614042219_add_indexed_public_catalog_facets.exs` adds btree/GIN/expression indexes for format, edition/original language, publication year/date, work subjects/title sort, contribution role joins, and source-record imported-at sorting.
  - `Hiraeth.AshPostgresMigrationTest` now asserts the facet/sort indexes exist in the migrated database.
  - `SearchLive` now accepts URL filter params (`q`, `publisher`, `role`, `contributor`, `format`, `language`, `subject`, `series`, `year`, `sort`) and delegates to `PublicCatalog.book_page/3`; the search form updates shareable query URLs instead of filtering streams in memory.
- Verification evidence:
  - `.omo/evidence/task-9-red-indexed-facets.txt` — RED migration/search URL tests before the facet indexes and `/search` param handling existed.
  - `.omo/evidence/task-9-test-migrate.txt` and `.omo/evidence/task-9-dev-migrate.txt` — test/dev databases applied the indexed facet migration.
  - `.omo/evidence/task-9-focused-tests.txt` — migration, PublicCatalog performance, and public LiveView tests passed: 25 tests, 0 failures.
  - `.omo/evidence/task-9-explain-clean.txt` — parameterized EXPLAIN probes captured representative publisher+translator, language+format, and ISBN/text search plans.
  - `.omo/evidence/task-9-search-http.txt` — `/search?q=9781646054541&format=paperback&sort=newest` returned HTTP 200 with exactly one matching work.
  - `.omo/evidence/task-9-format-check.txt`, `.omo/evidence/task-9-compile.txt`, `.omo/evidence/task-9-diff-check.txt`, and `.omo/evidence/task-9-ash-codegen-check.txt` — formatting, warning-free compile, whitespace, and AshPostgres codegen checks passed.

### T9 index-alignment remediation

- Independent verification found two indexes were present but not aligned with the predicates that should use them.
- Updated the public SQL filter predicates so:
  - Role filters compare `c.role = $n`, allowing the contribution role indexes to be used.
  - Subject filters use `w.subjects @> ARRAY[$n]::text[]`, allowing the work subjects GIN index to be used.
- Captured post-fix EXPLAIN evidence showing `Bitmap Index Scan` usage for `contributions_public_catalog_role_edition_index`, `editions_public_catalog_format_lower_index`, and `works_public_catalog_subjects_gin_index`.
- Verification evidence:
  - `.omo/evidence/task-9-green-index-alignment-tests.txt` — PublicCatalog performance tests remained green after predicate alignment.
  - `.omo/evidence/task-9-explain-post-review-fix.txt` — post-fix EXPLAIN output shows aligned role, format, subject, ISBN/source, and join index usage.
  - `.omo/evidence/task-9-focused-post-review-fix.txt` — migration, PublicCatalog performance, and public LiveView tests passed after remediation: 25 tests, 0 failures.
  - `.omo/evidence/task-9-search-http-post-review-fix.txt` — post-fix `/search?q=9781646054541&format=paperback&sort=newest` returned HTTP 200 with one matching work.
