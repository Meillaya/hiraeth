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
