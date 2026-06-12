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
