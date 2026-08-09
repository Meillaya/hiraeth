# F4 — Scope-Fidelity Verdict

**Plan:** `.omo/plans/test-full-and-bulk-nightly-seed.md`
**Reviewer role:** F4 Scope-Fidelity
**Base commit:** `912c0d8` (2026-08-07, "Merge pull request #3 from meillaya/devenv-restore-standalone")
**HEAD:** `7321fe0` ("record fallback not triggered", 2026-08-08)
**Date:** 2026-08-08
**Verdict:** **APPROVE**

All 12 guardrail checks pass with git evidence, the 22-commit inventory maps 1:1 to the plan's wave structure, and no scope creep, no OUT-guardrail violation, and no lost working-tree changes were found. The two additional hygiene commits beyond the plan's commit-per-todo count are plan-consistent test fixes with evidence logs.

---

## 1. Commit inventory (22 commits, `912c0d8..HEAD`)

Actual list — matches the expected list exactly (all 22 expected hashes present, in order), plus the two recorded in-scope hygiene commits (`10a944b`, `bdbf34b`):

| # | Commit | Message | Files (in-scope only) | Plan todo |
|---|--------|---------|----------------------|-----------|
| 1 | `9f5fd80` | chore(test): land lane-layer working tree | mix.exs, priv/test_lanes.exs, test/AGENTS.md, CHANGELOG.md, test/fixtures/committed_corpus_seed/{astra_house,mcnally_editions}.json, mix_alias_contract_test.exs, real_catalog_importer_test.exs | 1 |
| 2 | `b1a9599` | chore(test): land seed_provider task + tests | lib/mix/tasks/hiraeth.real_catalog.seed_provider.ex, seed_provider_task_test.exs, lib/mix/tasks/AGENTS.md, CHANGELOG.md | 1 |
| 3 | `7d913f8` | chore(config): land DATABASE_URL dev override | config/dev.exs, dev_database_url_override_test.exs, CHANGELOG.md | 1 |
| 4 | `ce2eebf` | chore(test): drop stale :nightly tag from fast cleanup reseed test | test/hiraeth/catalog/cleanup_test.exs | 1 (recorded deviation: own commit, plan-fine) |
| 5 | `8560e90` | chore(qa): record todo-1 landing and fresh-tree smoke evidence | artifacts/qa/wi1/{landing,fresh-tree-smoke}.log | 1 evidence |
| 6 | `dfdac03` | extend perf harness with lanes mode, per-file test.full timings, and nightly gate | scripts/qa/perf/measure_gates.sh, artifacts/qa/perf/{baseline-lanes.json, logs/*} | 2 |
| 7 | `96882bc` | record pre-fix test lane timing baseline | artifacts/qa/perf/{lanes-before.json, lanes-before-summary.json, shape-check.log} | 3 |
| 8 | `4b02ab6` | add nightly lane contract tests (red) | mix_alias_contract_test.exs, dev_environment_ci_contract_test.exs, artifacts/qa/wi2/contract-red.log | 4 |
| 9 | `2452e9f` | make :nightly a default-excluded opt-in test lane | priv/test_lanes.exs, test/test_helper.exs, artifacts/qa/wi2/mechanism-green.log | 5 |
| 10 | `10a944b` | fix(test): restrict corpus monsters to the :nightly lane tag | real_catalog_importer_test.exs, importer_provider_test.exs, mechanism-green.log (amendment) | 5/8 hygiene — de-tags monsters from :full_catalog/:slow so test.full's include-set can't match them (ExUnit include priority); membership re-proven in the amended evidence log |
| 11 | `bdbf34b` | fix(test): isolate seed_provider task test from committed corpus | seed_provider_task_test.exs, artifacts/qa/wi2/flake-fix.log | 1/5 hygiene — flake isolation for the landed test |
| 12 | `58bf9dd` | cut over nightly lane flags to the opt-in mechanism | deep.yml, Makefile, artifacts/qa/wi2/ci-cutover.log | 6 |
| 13 | `db613c4` | document nightly opt-in lane semantics | AGENTS.md, README.md, test/AGENTS.md, CHANGELOG.md, docs-green.log | 7 |
| 14 | `33558f6` | record post-lane-fix timing evidence | artifacts/qa/perf/{lanes-after-wi1.json, SUMMARY-wi1.md, logs/*}, artifacts/qa/wi3/membership.log | 8 |
| 15 | `31e9f72` | validate bulk upsert mechanism for importer rewrite | test/hiraeth/real_catalog/bulk_spike_test.exs, artifacts/qa/wi2/{bulk-spike.json, bulk-spike.log, spike-decision.md} | 9 |
| 16 | `24d9da8` | rewrite corpus seeding as bulk upsert pipeline | lib/hiraeth/real_catalog/importer.ex, bulk_spike_test.exs, artifacts/qa/wi4/bulk-seed-green.log | 10 |
| 17 | `e9ec20f` | align seed_provider! with the bulk pipeline | artifacts/qa/wi4/seed-provider-green.log | 11 (importer.ex already updated in 24d9da8; single shared pipeline per plan decision) |
| 18 | `17d47dc` | lock bulk importer semantics with contract and envelope tests | bulk_spike_test.exs, real_catalog_importer_test.exs, importer.ex, artifacts/qa/wi4/bulk-contract-green.log | 12 |
| 19 | `eed59b7` | stop bulk contract suite from overwriting spike evidence | bulk_spike_test.exs, artifacts/qa/wi4/bulk-contract-timings.json | 12 hygiene |
| 20 | `bfca6e3` | sync docs and comments with measured bulk envelopes | deep.yml, Makefile, CHANGELOG.md, lib/hiraeth/real_catalog/AGENTS.md, importer_provider_test.exs, real_catalog_importer_test.exs, doc-sync.log | 13 |
| 21 | `648e437` | record final verification timings and coverage floor check | artifacts/qa/perf/{lanes-final.json, coverage-final.json, SUMMARY.md, logs/*}, wi4/bulk-contract-timings.json | 14 |
| 22 | `7321fe0` | record fallback not triggered | artifacts/qa/wi5/fallback-not-triggered.log | 15 (NOT TRIGGERED, correct: test_full_ms 243,911 ≤ 300,000) |

Per-commit `--name-status` verified: every file in every commit is within the plan's IN list or is a gitignored evidence artifact force-added under `artifacts/qa/` (31 tracked evidence files; `.omo/` and `artifacts/` are gitignored — tracked evidence is the expected `git add -f` pattern).

## 2. Guardrail-by-guardrail check (with evidence)

| # | Guardrail | Command | Result |
|---|-----------|---------|--------|
| G1 | Corpus/manifests/snapshots untouched | `git log --oneline --stat 912c0d8..HEAD -- priv/catalog_sources/` | **PASS** — zero output (EMPTY) |
| G2 | Cover cache untouched | `git log --oneline --stat 912c0d8..HEAD -- priv/static/covers/` | **PASS** — zero output (EMPTY) |
| G3 | Migrations untouched | `git log --oneline --stat 912c0d8..HEAD -- priv/repo/migrations/` | **PASS** — zero output (EMPTY) |
| G4 | No dependency changes | `git diff 912c0d8 HEAD -- mix.exs mix.lock` | **PASS** — mix.exs diff is only the test_lanes alias assembly (`test.fast: ["test #{exclude_args()}"]`, `test.full: ["test #{include_args()}"]`, new private `test_lanes/exclude_args/include_args`); mix.lock absent from diff → unchanged; deps section untouched |
| G5 | ci.yml untouched | `git diff 912c0d8 HEAD -- .github/workflows/ci.yml` | **PASS** — EMPTY (exit 0, no output) |
| G6 | `mix gate` composition unchanged | same mix.exs diff | **PASS** — `gate:` alias (compile --warnings-as-errors, deps.unlock, format check, credo, test.fast) byte-identical; only the fast/full lane aliases re-assembled from `priv/test_lanes.exs` with the *same tag set* (slow, full_catalog, integration, performance, browser, public_catalog_full — verified in `priv/test_lanes.exs`) |
| G7 | No `:id` writability changes | `git log -p 912c0d8..HEAD -- lib/hiraeth/catalog/ \| grep "writable? true"` | **PASS** — zero matches (grep exit 1); also: `lib/hiraeth/catalog/` itself has **no commits in range**; bulk path precomputes no ids (Ash generates, per todo 9 GO criteria) |
| G8 | No `:replace_all` | `grep -rn "replace_all" lib/hiraeth/` | **PASS** — only 2 hits, both documentation text: `real_catalog/AGENTS.md:37` and `importer.ex:33` moduledoc — each says "NEVER `:replace_all`". No code usage. |
| G9 | Public API surface unchanged | `git diff 912c0d8 HEAD -- lib/hiraeth_web/router.ex lib/hiraeth_web/public_catalog.ex` | **PASS** — EMPTY. `lib/hiraeth_web/` has zero commits in range |
| G10 | No unrelated working-tree changes lost | `git status --porcelain -uall` | **PASS** — clean (no output). `.omo/`/`artifacts/` gitignored tool/evidence state only |
| G11 | No deep-lane job removed / no public route change | `git diff 912c0d8 HEAD -- .github/workflows/deep.yml` | **PASS** — flag mechanics only: `--exclude nightly` dropped from full-suite job, `--include nightly` added to coverage job, comment blocks updated; no job added/removed; no `pull_request` trigger introduced |
| G12 | Domain modules untouched | `git diff --name-only 912c0d8 HEAD` | **PASS** — only `lib/hiraeth/real_catalog/importer.ex` + `real_catalog/AGENTS.md` under lib/hiraeth; zero commits in `lib/hiraeth/catalog`, `ingestion`, `sources`, `covers` |

## 3. Scope-creep check

Every added/modified file maps to a plan IN item or a plan-mandated evidence artifact:

- `priv/test_lanes.exs`, `test/test_helper.exs`, `mix.exs` → IN (lane mechanism, single source of truth)
- `test/hiraeth/mix_alias_contract_test.exs`, `dev_environment_ci_contract_test.exs` → IN (contract locks)
- `.github/workflows/deep.yml`, `Makefile`, `scripts/qa/perf/measure_gates.sh` → IN (flag cutover + harness lanes mode)
- `lib/hiraeth/real_catalog/importer.ex` internals + `real_catalog/AGENTS.md` + `test/hiraeth/real_catalog/bulk_spike_test.exs` → IN (WI2 bulk rewrite + contract/envelope tests, todos 9–12)
- `lib/mix/tasks/hiraeth.real_catalog.seed_provider.ex` + tests, `config/dev.exs` + test, `test/fixtures/committed_corpus_seed/` → IN (todo 1 landing of prior uncommitted layer)
- `test/hiraeth/catalog/cleanup_test.exs` → IN (tag/comment hygiene, todo 1b)
- Docs (`AGENTS.md`, `test/AGENTS.md`, `README.md`, `CHANGELOG.md`, `lib/mix/tasks/AGENTS.md`) → IN (todos 1, 7, 13)
- `artifacts/qa/**` evidence → plan-mandated per-todo evidence; 31 files tracked (git add -f, expected)
- `10a944b` (monster de-tag) and `bdbf34b` (seed_provider test isolation) → hygiene beyond the strict commit-per-todo count, but both plan-consistent: the de-tag is required for the plan's own membership invariant ("test.full runs ZERO :nightly tests" — proven in the amended `mechanism-green.log`: test.full include-set simulation 19 tests/2 excluded, `--only nightly` = exactly 2), and the isolation fix stabilizes a todo-1-landed test. Each carries its own evidence log and gate runs.
- **Nothing flagged.** No changes to `config/test.exs` (fallback NOT TRIGGERED, correct — `test_full_ms` 243,911 ≤ 300,000 hard budget), no new deps, no schema changes, no public API, no parallelism changes.

## 4. Working-tree / loss check

- `git status --porcelain -uall` → clean at review time. The prior turn's uncommitted layer (lane files, importer test split, seed_provider task, DATABASE_URL override) is fully landed across commits 1–3 (+ hygiene 4); nothing uncommitted remains.
- Evidence artifacts live under gitignored `artifacts/` and `.omo/`; the tracked subset (31 files) is the plan's expected `git add -f` committed evidence.

## 5. Notes

- Recorded deviation confirmed: `ce2eebf` (cleanup_test tag hygiene) landed as its own commit instead of inside commit 1 — plan-fine, atomicity preserved (the plan explicitly folds it into todo 1, and its landing order/contents match todo 1b exactly: `:nightly` dropped, `:full_catalog :slow` + `timeout: 120_000` kept, stale comment replaced).
- The `test.full` alias now assembles `--include <slow_tags>` (nightly NOT in the include set); combined with the test_helper `exclude: [:nightly]`, ExUnit's include-wins-over-exclude rule made the monster de-tag (10a944b) load-bearing — this is exactly the membership contract the plan requires, and it is evidence-locked in `mechanism-green.log` and `lanes-after-wi1.json`/`lanes-final.json`.

---

**VERDICT: APPROVE** — no OUT guardrail violated, no scope creep, no lost changes; 22/22 commits in scope; evidence recorded for every guardrail check above.
