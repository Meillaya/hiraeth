# Final Verification — Bulk Seed Rewrite (Before → WI1 → Final)

**Date:** 2026-08-08
**HEAD (final):** bfca6e3 (post-WI2 bulk rewrite — todos 1-13 landed)
**Harness:** `PERF_NO_DEVENV=1 PERF_OUT=artifacts/qa/perf/lanes-final.json bash scripts/qa/perf/measure_gates.sh --only lanes` (5 gates; test.full & test.nightly run `--slowest 50`)
**Evidence files:** `lanes-before.json` (todo 3) → `lanes-after-wi1.json` (todo 8) → `lanes-final.json` (this todo, real run, exit 0, wall 411s); `coverage-final.json` (this todo)

## Gate comparison (ms)

| Gate | before (8560e90) | after-WI1 (db613c4) | final (bfca6e3) | final vs before | final vs WI1 |
|---|---|---|---|---|---|
| blocked-check | 11 | 6 | 6 | -45% | 0% |
| compile | 506 | 470 | 459 | -9% | -2% |
| test.fast | 15,912 | 15,872 | 15,436 | -3% | -3% |
| **test.full** | **1,138,814** | **344,874** | **243,911** | **-78.6% (-894,903)** | **-29.3% (-100,963)** |
| **test.nightly** | **186,779** | **537,497** | **151,039** | **-19.1%** | **-71.9% (-386,458)** |
| totals.elapsed_ms | 1,342,251 | 898,934 | 411,075 | -69.4% | -54.3% |

All three runs: 0 failed gates, `error: null`. Final run: 5/5 gates passed, harness exit 0, 36-file per-file aggregation.

## Budget adjudication (the plan's decisive evidence)

### test.full: 243,911ms — PASS (≤ 300,000ms budget; 56,089ms headroom)

- The ≤5-min criterion is met **warm** with 18.7% margin. Final is -29.3% vs the post-WI1 344,874ms (which still paid a per-record-rate hidden reseed) — the bulk rewrite's ~60s reseed (todo 10 measured 59.8s public reseed) plus the importer-file per-record tail removal accounts for the drop. The two `:nightly` monsters are membership-proven excluded from test.full (2 `(excluded)` occurrences in `test.full.log`; include-set `slow_tags` cannot match them — todo 5 amendment).
- **Todo 15 (conditional fallback) is NOT triggered:** `test_full_ms` = 243,911 ≤ 300,000.

### test.nightly: 151,039ms — PASS (lane wall < 300,000ms; per-seed envelope 49.4s ≪ 300s hard gate)

- Lane wall 151.0s (2.5 min) is **under the 5-min budget** — the todo-12 risk flag (~315s local lane wall) did NOT materialize; the final run measured 151s (corpus JSONs warm in OS page cache after the preceding test.full gate + bulk rewrite). Recorded honestly: a cold page-cache run may land higher, but the per-seed WI2 hard gate is what's asserted.
- Duration-anchored, exactly 3 tests ran (525 collected, 522 excluded):
  - `real catalog importer handles the full real_publishers corpus end-to-end` — **50,052.1ms**
  - `existing seed!/1 still works after adding seed_provider!/2` — **49,616.5ms**
  - `bulk full-corpus seed completes within the 300s perf envelope` — **49,410.5ms** (assert <300,000ms — 83.5% margin; target ≤120s also met)
- Before-state nightly 186,779ms was a same-run warm artifact (monsters ran inside the preceding test.full, find-or-create no-op); post-WI1 537,497ms was the cold per-record truth; final 151,039ms is the post-bulk truth — the monsters dropped from 271s+265s (post-WI1) to ~50s each.

### Coverage floor (Finding 12 pre-merge check): 87.1% — PASS (≥ 86.1 floor)

- `MIX_ENV=test mix coveralls --include nightly --max-cases 8`: exit 0, wall 348.9s, **TOTAL 87.1%** (recorded in `coverage-final.json`).
- `Including tags: [:nightly]` honored; 0 excluded → all 525 tests ran, including the 2 monsters + envelope (the exact suite the deep.yml nightly coverage job runs).
- **No `coveralls.json` adjustment made** — the floor was NOT breached. The bulk rewrite's deleted per-record code paths did not drop measured coverage below 86.1; the pre-decided adjustment rule was not needed, and no regression is being hidden.

### test.fast: 15,436ms — PASS (≈16s expectation, unchanged)

## Success-criteria check

- [x] `mix test.full` warm ≤5 min (243.9s), 0 failures, ZERO `:nightly` tests run (membership-proven via log)
- [x] Nightly lane <5 min (151.0s local; target ≤2 min approached), 0 failures; per-seed envelope 49.4s < 300s hard assert
- [x] `:nightly` first-class opt-in lane, contract-locked, honored by every lane + coveralls (`--include nightly` confirmed in coveralls output)
- [x] Importer public contracts unchanged — proven by the unchanged suite (525 tests, 0 failures across gate, harness, and coveralls runs)
- [x] Before/after evidence committed; coverage floor documented and verified pre-merge
- [x] `mix gate` warm: exit 0, 15.4s wall, 525 tests 0 failures 116 excluded

## Notes

- coveralls wall 348.9s (instrumented) vs 243.9s un-instrumented test.full gate — instrumentation overhead plus the 3 nightly tests, as expected.
- Per-file residual (final run): `real_catalog_importer_test.exs` 219,468ms sum (incl. nightly monster runs aggregated across logs), `importer_provider_test.exs` 49,687ms, `real_catalog_dataset_test.exs` 20,670ms — the dataset-contract tests remain the largest non-nightly cost, all under budget.
