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
