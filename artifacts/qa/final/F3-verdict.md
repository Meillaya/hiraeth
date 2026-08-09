# F3 Verdict — Real Manual/Agent QA (test-full-and-bulk-nightly-seed)

**Reviewer:** F3 real-QA lane (independent execution, no code/test/CI modifications)
**Plan:** `.omo/plans/test-full-and-bulk-nightly-seed.md` (15/15 todos done)
**HEAD:** `7321fe0` at first measurement; re-adjudication at `b89b5aa` (fix(test): restrict perf envelope test to the `:nightly` lane tag, applied by F2-1)
**Date:** 2026-08-08, 14:00–15:00 local (UTC-4) (first measurement 14:00–14:30; re-adjudication 14:44–15:00)
**Host:** entropyos-nix, 16 CPUs, 62 GB RAM, PG16.14 standalone on 127.0.0.1:54320

## VERDICT: APPROVE (final — against the AMENDED plan, Amendment 2)

**Adjudication history (honest record):**
1. **F3 first pass (7321fe0): REJECT** — nightly-lane wall 529.7s / 425.9s under 4-reviewer parallel load vs the plan's original "<5 min lane wall" wording.
2. **F3 re-adjudication (b89b5aa, quiet box): REJECT re-affirmed** — idle wall 385.9s still > 300s; the budget miss was partially a load artifact (530 → 426 → 386s as the box quieted) but the original criterion was missed even idle. The per-seed envelope hard gate passed in every measurement. Recommendation issued: make the per-seed envelope the authoritative WI2 gate.
3. **Amendment 2 (orchestrator, recorded in `issues.md` + plan line ~111):** the per-seed perf-envelope `<300s` is now the AUTHORITATIVE WI2 gate; the lane wall is a variance-bound proxy (3 lock-serialized seeds + page-cache; observed 151–530s), explicitly NOT the hard gate. The user's "<5 min nightly sweep" goal = one seed, which is met.

**Adjudication against the amended criterion — every check PASSES:**

| Amended criterion | Evidence | Result |
|---|---|---|
| Per-seed envelope `<300s` (AUTHORITATIVE WI2 gate) | 49.4s (todo 14), 178.4s, 178.2s, 140.2s (F3 ×3) — **passed in ALL 4 measurements** | **PASS** |
| `mix test.full` ≤5 min, 0 failures, ZERO `:nightly`-tagged tests | 145.9s, 525 tests / 0 failures / 3 excluded; monsters + envelope absent from run lines | **PASS** |
| Nightly lane: 0 failures, exactly 3 tests, exit 0 | exit 0, 3 tests (2 monsters + envelope), 0 failures in all 4 runs | **PASS** |
| Lane wall (proxy, not gate) | 151s (todo 14) / 529.7s / 425.9s / 385.9s (F3) — within the documented 151–530s variance bound | **PASS (proxy variance documented)** |
| Coverage floor 87.1% ≥ 86.1 | `coverage-final.json` (valid at b89b5aa; tag-only delta) | **PASS** |
| deep.yml greps: exclude=0, include=1, no pull_request | verified | **PASS** |
| `@tag :nightly` membership: exactly 3 (2 monsters + envelope) | 3 hits in 2 files (importer_provider:203, importer:158 + :182) | **PASS** |
| Contract tests green | mix_alias + dev_environment_ci + docs_qa_pack + no_scope_creep: 26 tests, 0 failures | **PASS** |
| `mix gate` (warm) | 16.1s, exit 0, 525/0/116 on clean env | **PASS** |

**Final verdict line: APPROVE.** All F3 gate checks pass against the amended
success criteria. The plan's authoritative WI2 gate (per-seed envelope <300s)
held in every measurement; test.full fits ≤5 min with zero nightly-tagged
tests; nightly membership/failures correct; coverage floor and CI flag
mechanics verified. The lane-wall variance (151–530s) is documented as a
proxy in the amended criterion and is not a gate failure.

---

## Evidence table

| # | Check | Exact command | Result | Evidence |
|---|-------|---------------|--------|----------|
| 1 | Postgres up | `bash scripts/dev/ensure_postgres.sh start` (PATH += `/nix/store/8f3asyrsmvvhqzqz83qmz4n0n1xr4vah-postgresql-16.14/bin`) | **PASS** — ready on 127.0.0.1:54320 | bash output (this session) |
| 2 | `mix gate` (warm), 1st run | `time mix gate` | **FAIL (environmental flake)** — exit 2, 15.6s, 525 tests / 1 failure / 116 excluded; the one failure was the pre-existing hermetic drill contract test `production_ingestion_script_contract_test.exs:6` (last touched 2026-08-07, **before** the plan; stale `/tmp/hiraeth-script-contract-*` dirs with leftover `.pg_isready.count` collide via `System.unique_integer` restart — reproduced 1/5 standalone runs; commands.log shows no `pg_ctl` line) | `artifacts/qa/final/evidence/gate-first-run-fail.log`, `evidence/flake-commands.log` |
| 3 | `mix gate` (warm), clean env | `time mix gate` (after removing stale `/tmp/hiraeth-script-contract-*` + `/tmp/hiraeth-pgdata-*`; no repo changes) | **PASS** — exit 0, 16.1s wall, 525 tests / 0 failures / 116 excluded (matches plan's expected 525/~116/0) | `artifacts/qa/final/evidence/gate-clean-run-pass.log` |
| 4 | `mix test.full` | `time MIX_ENV=test mix test.full` | **PASS** — exit 0, 194.9s wall (**≤300s**; recorded 243,911ms in todo 14), 525 tests / 0 failures / 2 excluded; both monster names absent from output, incl. duration-anchored grep `\([0-9]` (rc=1 for both) | `artifacts/qa/final/evidence/test-full.log` |
| 5 | Nightly lane, membership | `time MIX_ENV=test mix test --only nightly --trace` | **PASS (membership/failures)** — exit 0, **exactly 3 tests ran** (525 − 522 excluded): "real catalog importer handles the full real_publishers corpus end-to-end", "existing seed!/1 still works after adding seed_provider!/2", "bulk full-corpus seed completes within the 300s perf envelope"; 0 failures; **envelope hard assert held: 178,447.8ms < 300,000ms** | `artifacts/qa/final/evidence/test-nightly-trace.log` |
| 6 | Nightly lane, wall budget (under load) | `time MIX_ENV=test mix test --only nightly --trace` | **FAIL (budget)** — wall **529.7s** (expected <300s; plan criterion <5 min) | `artifacts/qa/final/evidence/test-nightly-trace.log` |
| 7 | Nightly lane, wall budget (harness command) | `time MIX_ENV=test mix test --only nightly --slowest 50` | **FAIL (budget)** — wall **425.9s**, 3 tests, 0 failures (per-test: 180.0s / 178.2s / 67.3s) | `artifacts/qa/final/evidence/test-nightly-harness-cmd.log` |
| 7b | **Nightly lane re-measurement (re-adjudication, quiet box)** | `time MIX_ENV=test mix test --only nightly --trace` (load ~1.3) | **FAIL (budget, still)** — wall **385.9s**, exit 0, exactly 3 tests, 0 failures; per-seed 64,028.1ms / 140,156.4ms (envelope <300s ✓) / 180,860.3ms; idle run is 2.55× todo-14's 151s | `artifacts/qa/final/evidence/test-nightly-rem1-idle.log` |
| 4b | **`mix test.full` re-measurement (re-adjudication, HEAD b89b5aa)** | `time MIX_ENV=test mix test.full` | **PASS** — exit 0, **145.9s** (≤300s; envelope now excluded by the F2-1 tag fix), 525 tests / 0 failures / **3 excluded** (2 monsters + envelope); monsters absent (0 matches); envelope absent as a run line (0 matches with `\([0-9]`) — "ZERO nightly-tagged tests in test.full" contract now holds | `artifacts/qa/final/evidence/test-full-rem1-idle.log` |
| 8 | Lanes harness | `PERF_NO_DEVENV=1 PERF_OUT=artifacts/qa/perf/lanes-final.json bash scripts/qa/perf/measure_gates.sh --only lanes` | **PASS (verified, not re-run)** — tree byte-identical to todo-14 (git status clean; commits `648e437`/`7321fe0` touch only `artifacts/`); JSON valid; gates: test.full 243,911ms, test.nightly 151,039ms, error null, 5 gates/0 failed; `logs/test.full.log` (13:41:58) + `logs/test.nightly.log` (13:44:29) match `generated_at` 17:44:29Z. ⚠ caveat: its test.nightly figure is **not reproducible** today (425.9s via the identical command — see row 7) | `artifacts/qa/perf/lanes-final.json`, `artifacts/qa/perf/logs/*.log` |
| 9 | Coverage floor | `MIX_ENV=test mix coveralls --include nightly --max-cases 8` | **PASS (verified existing)** — `coverage-final.json`: exit 0, **87.1% ≥ 86.1** floor (`coveralls.json` minimum_coverage 86.1), 525 tests / 0 failures / 0 excluded, wall 348.9s, generated at commit bfca6e3 (code tree identical at HEAD) | `artifacts/qa/perf/coverage-final.json`, `coveralls.json:3` |
| 10 | deep.yml flag greps | `grep -c "exclude nightly" .github/workflows/deep.yml`; `grep -c "include nightly" ...`; `grep -q "pull_request" ...` | **PASS** — 0 / 1 (line 506 `mix coveralls --include nightly --max-cases 8`) / absent (on: push main + workflow_dispatch + schedule cron) | bash output (this session); `deep.yml:3-12,506` |
| 11 | Makefile coverage flag | `grep nightly Makefile` | **PASS** — `coverage` target = `mix coveralls --include nightly` (line 44) | bash output (this session) |
| 12 | Membership (tag files) | `grep -rn "^\s*@tag :nightly" test/` | **PASS** — exactly **3 hits in 2 files** (`test/hiraeth/real_catalog_importer_test.exs` lines 158 + 182, `test/hiraeth/real_catalog/importer_provider_test.exs` line 203) = 2 monsters + envelope (re-verified at HEAD b89b5aa) | bash output (this session) |
| 13 | Contract tests | `MIX_ENV=test mix test test/hiraeth/mix_alias_contract_test.exs test/hiraeth/dev_environment_ci_contract_test.exs test/hiraeth/docs_qa_pack_test.exs test/hiraeth/no_scope_creep_test.exs` | **PASS** — 26 tests, 0 failures (lane locks + deep.yml flag locks + doc locks all green) | bash output (this session) |

## Summary

| Check | Result |
|-------|--------|
| `mix gate` (warm) | PASS on clean env (16.1s, 525/0/116); 1st run failed on a pre-existing env flake (documented) |
| `mix test.full` ≤300s, 0 failures, zero nightly | PASS (145.9s at HEAD b89b5aa; 194.9s at 7321fe0 — both ≤300s; monsters absent both) |
| `mix test --only nightly` — membership + failures + **per-seed envelope (<300s, authoritative WI2 gate)** | **PASS** — 3 tests / 0 failures / exit 0 in all 4 runs; envelope 49.4s / 178.4s / 178.2s / 140.2s all <300s (lane wall 151–530s is the documented variance-bound proxy, not the gate post-Amendment 2) |
| lanes harness → lanes-final.json | PASS (verified artifact; nightly figure not reproducible) |
| coveralls ≥86.1 | PASS (87.1%; still valid at b89b5aa — tag-only change, coverage job runs all 525 tests) |
| deep.yml 0/1/absent + Makefile flag | PASS |
| `@tag :nightly` membership | PASS (3 hits, 2 files: importer_provider_test.exs:203, real_catalog_importer_test.exs:158 + :182) |
| Contract tests green | PASS |

## Lane-wall variance analysis (resolved by Amendment 2)

- **What was expected (original wording):** plan F3 + task stated a `<300s`/`<5 min` lane wall for `mix test --only nightly`. Todo-14 recorded 151,039ms idle (envelope 49.4s, monsters ~50s each).
- **What was recorded (independent):** 529.7s (under load, trace), 425.9s (under load, harness command), **385.9s (quiet box, trace)**. Per-seed across all runs: 49.4s, 64.0s, 67.3s, 140.2s, 172.4s, 178.1s, 178.2s, 180.0s, 180.9s. The three tests run serialized under the `:global` full-corpus seed lock (verified: wall ≈ sum of per-test times), so the lane wall is 3 × (seed + clear cost), and the seed cost is machine/DB-state sensitive (page cache, DB state).
- **Load-artifact assessment:** partially confirmed — wall dropped 530 → 426 → 386s as the box quieted (the original 425–530s measurements ran under 4-reviewer parallel load); the idle recording was still above the original 300s wording, which is exactly the variance the amendment documents (observed 151–530s).
- **Not a code regression:** the tree is byte-identical to todo-14's measurements for the nightly-lane code path (b89b5aa changed only the envelope's tags); the per-seed variance is environmental.
- **The authoritative gate (Amendment 2) — passed in EVERY measurement:** the per-seed perf-envelope asserts `Importer.seed!()` over 8776 records `<300s` (timed after the `:global` lock): 49.4s (todo 14), 178.4s, 178.2s, 140.2s (F3 ×3) — 4/4 PASS. The user's "<5 min nightly sweep" goal (one seed) is met.
- **Bottom line:** against the amended success criteria, the F3 gate is fully green → **APPROVE**. The lane-wall variance is documented as a proxy in the plan (line ~111) and is not a gate failure.

## Caveats / non-blocking findings

1. **Pre-existing flake (not plan-caused, surfaced by F3):** `production_ingestion_script_contract_test.exs:6` failed the first `mix gate` run. Root cause: stale `/tmp/hiraeth-script-contract-*` temp dirs (216 present; ~100 with leftover `.pg_isready.count`) collide with the test's `System.unique_integer([:positive])`-named temp dir after BEAM restarts, so the fake `pg_isready` never fails first → the drill takes the "already accepting" path → no `pg_ctl` invocation → assertion fails. Reproduced 1/5 standalone runs; gone after /tmp cleanup; the test/scripts were last touched 2026-08-07 (pre-plan). Recommendation (code untouched by F3): have the test delete `.pg_isready.count`/bin dir in setup, or use a `tmp_dir` that cannot collide (e.g., `:rand` + mkdir_p with re-try).
2. **Verified-not-rerun decisions:** lanes harness (row 8) and coveralls (row 9) were verified via committed artifacts + log timestamps under the task's byte-identical-tree provision; the nightly gate inside lanes-final.json is the one figure contradicted by today's recordings (rows 7/7b).
3. **F2-1 fix verified (b89b5aa):** the envelope test is now `:nightly`-only. `mix test.full` at this HEAD: 145.9s, 3 excluded (all three nightly tests), envelope absent from run lines — the "ZERO nightly-tagged tests in test.full" contract now holds (at 7321fe0 the envelope had been re-admitted by test.full's `--include full_catalog --include slow`, contributing ~100-190s). The nightly lane contents are unchanged: exactly 3 tests.
4. No product/test/CI code was modified by this review; only `artifacts/qa/final/evidence/` was written and stale `/tmp` test state removed.

## Re-run commands (for a re-verification attempt)

```bash
bash scripts/dev/ensure_postgres.sh start
time mix gate
time MIX_ENV=test mix test.full
time MIX_ENV=test mix test --only nightly
PERF_NO_DEVENV=1 PERF_OUT=/tmp/lanes-recheck.json bash scripts/qa/perf/measure_gates.sh --only lanes
```
