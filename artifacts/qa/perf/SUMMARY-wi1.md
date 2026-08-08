# WI1 Lane-Fix Verification — Before/After Timing Evidence

**Date:** 2026-08-08
**HEAD (before):** dfdac03 (harness extended, pre-lane-fix)
**HEAD (after):** db613c4 (post-WI1: :nightly opt-in lane landed — todos 1-7)
**Harness:** `PERF_NO_DEVENV=1 bash scripts/qa/perf/measure_gates.sh --only lanes` (5 gates; test.full & test.nightly run `--slowest 50`)
**Evidence files:** `lanes-before.json` (derived from baseline-lanes.json, todo 2/3) vs `lanes-after-wi1.json` (real run this todo, exit 0, wall 899s)

## Gate comparison

| Gate | before (ms) | after (ms) | delta | delta % |
|---|---|---|---|---|
| blocked-check | 11 | 6 | -5 | -45.5% |
| compile | 506 | 470 | -36 | -7.1% |
| test.fast | 15,912 | 15,872 | -40 | -0.3% |
| **test.full** | **1,138,814** | **344,874** | **-793,940** | **-69.7%** |
| **test.nightly** | **186,779** | **537,497** | **+350,718** | **+187.8%** |
| totals.elapsed_ms | 1,342,251 | 898,934 | -443,317 | -33.0% |

Both runs: all 5 gates passed, `error: null`, 0 failed gates. Lane membership proven in `artifacts/qa/wi3/membership.log` (see below).

## Membership QA (deterministic, before the harness run)

Recorded in `artifacts/qa/wi3/membership.log`:

1. **`mix test --only nightly --trace`** → `516 tests, 0 failures, 514 excluded`, exit 0, 410.4s.
   Duration-anchored proof — exactly 2 tests RAN:
   - `test real catalog importer handles the full real_publishers corpus end-to-end` (304,720.5ms)
   - `test existing seed!/1 still works after adding seed_provider!/2` (104,721.3ms)
   Zero `(excluded)` occurrences for either name in this run.
2. **`mix test --include full_catalog --include slow test/hiraeth/real_catalog_importer_test.exs test/hiraeth/real_catalog/importer_provider_test.exs --trace`** → `19 tests, 0 failures, 2 excluded`, exit 0, 27.9s.
   Both monsters appear exactly once as `(excluded)`; zero duration-anchored runs — the `test.full` include-set (`slow_tags`: `:full_catalog`, `:slow`) no longer matches them (they now carry only `:nightly` + `timeout`). This is the cheap deterministic proof that `mix test.full` excludes them.
3. Full collection count at this HEAD: **N = 516** (both lanes report it; `test.full` = 516/0/2 excluded, `test.nightly` = 516/0/514 excluded).

The after-state harness logs independently confirm: `test.full.log` shows both monsters `(excluded)`; `test.nightly.log` shows exactly the 2 monsters ran (271,094.0ms + 264,703.1ms).

## test.full: 1,138,814ms → 344,874ms (-69.7%)

The two monsters contributed 388,648ms to the before-state test.full (100,971ms importer + 287,677ms provider per the before-run per-file map); they are now excluded (membership-proven above), and the gate dropped by 793,940ms. The remaining 344,874ms is the WI1 residual:

- **No test in the top-50 exceeds ~1s** — the residual is spread: `Top 50 slowest (108.2s), 31.4% of total time`; ~237s sits in the long tail of 464 tests.
- **test.full-only per-file cost (from its own `--slowest 50`):** `real_catalog_importer_test.exs` 33,793ms (its non-monster tests use per-record `Ash.create!`), `real_catalog_dataset_test.exs` 21,687ms (14 dataset-contract entries in the top-50), `public_catalog_live_test.exs` 10,583ms, `auto_ingest_e2e_test.exs` 9,207ms, `public_catalog_performance_test.exs` 7,386ms.
- **The hidden committed full-corpus reseed did NOT fire in this run** (measured by the slowest-50 percentage math: top-50 108.2s / 31.4% ⇒ total ≈ 344.6s ≈ gate time, leaving no room for a ~240s reseed; the corpus was already committed from earlier runs the same day, so the first public module's `ensure_committed_catalog_fixtures!` was a no-op, and `seed_provider_task_test.exs`'s `:reset_committed_catalog` moduletag deletes the committed corpus mid-suite). The before-state 1,138,814ms DID include it (monsters 388,648 + reseed ~240s + long tail ≈ 1,138.6s ✓). **On a cold DB (fresh CI box) the reseed still costs ~240s** — plan-estimated cold residual 750-850s; the measured 344.9s is the warm floor. **The reseed is the top WI2 target.**

## test.nightly: 186,779ms → 537,497ms (+187.8%) — WARM vs COLD, not a regression

The before-state 186,779ms was a **same-run warm artifact**: in that harness run the monsters had just run inside the preceding test.full gate (they were part of it pre-WI1), so the nightly gate's monsters found the full corpus already committed and their `seed!()` took the find-or-create no-op path (~93s each).

Post-WI1 the nightly lane is the sole owner of the monster cost and pays it **cold**: during the after-run's test.full, the `:reset_committed_catalog` moduletag deleted the committed corpus, so the nightly monsters' `seed!()` was a full 8,776-record insert over an empty catalog — 271,094ms + 264,703ms = 535,797ms of the 537,497ms gate. The standalone 2a run (410.4s, monsters 304.7s + 104.7s) brackets the same cold truth: **post-WI1 nightly ≈ 410-537s, entirely the monsters' per-record `Ash.create!` seed path.** This is unchanged by WI1 by design (WI1 only moved them into the lane) and is exactly what WI2's bulk rewrite + <300s envelope test must eliminate.

## Residual analysis — what WI2 must eliminate

1. **The hidden committed full-corpus reseed (~240s cold)** — invisible in this warm run, present in every fresh-DB/CI run; plan-estimated cold test.full ≈ 750-850s. WI2's bulk `seed!` removes it as a cost multiplier.
2. **The per-record `Ash.create!` long tail** — importer file 33.8s + dataset contracts 21.7s in the top-50, ~237s in the 464-test tail (514 tests × ~670ms avg). Bulk upserts flow directly into the importer's own tests.
3. **The nightly monsters (536s of the 537.5s gate)** — the per-record seed path at full-corpus scale; WI2's envelope target (<300s, target ≤120s) is asserted on this exact lane.

## Adjudication

- Membership: PASS — exactly 2 `:nightly` tests; both excluded from every include-set `test.full` can produce; N = 516.
- Both lanes: 0 failures (test.full 516/0/2, test.nightly 516/0/514); harness exit 0; JSON valid (`error: null`, `gates_failed: 0`).
- No code touched: measurement-only todo (git status clean of product/test/CI changes before commit).
- WI1 target met: monsters removed from `mix test.full` (-793,940ms); `test.nightly` unchanged in ownership (2 monsters, cold 410-537s) — both recorded honestly above.
