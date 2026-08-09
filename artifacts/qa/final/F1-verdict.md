# F1 — Plan-Compliance Verdict: test-full-and-bulk-nightly-seed

**Reviewer:** F1 (plan-compliance audit, read-only)
**Date:** 2026-08-08
**Plan:** `.omo/plans/test-full-and-bulk-nightly-seed.md` (15 todos)
**Draft decisions:** `.omo/drafts/test-full-and-bulk-nightly-seed.md` (D1–D13, as revised by Metis findings 1–20)
**Range reviewed:** `912c0d8..HEAD` (19 commits: 3 concern-grouped landing + 12 todo commits + 2 follow-ups)
**Verdict: ✅ APPROVE**

---

## Verdict summary

All 15 todos' references/acceptances are satisfied with committed evidence. No OUT guardrail was violated. The uncommitted-layer landing matches the recorded decisions (D11), including the ImportRun assertion fix, the cleanup_test tag hygiene, the `app_dir` alignment, and the tmp-dir isolation of the seed_provider task test. Deviations that occurred mid-execution (ExUnit include-priority discovery, spike ratio 6.3x vs literal 10x, batch_size probe error type) were each recorded with evidence and resolved/adjudicated in-document — none weakened an acceptance criterion.

## Per-todo compliance table

| # | Acceptance claimed | Evidence verified | Result |
|---|---|---|---|
| 1 | Land uncommitted layer in 3 concern-grouped commits; fix red ImportRun assertion; cleanup_test tag hygiene; seed_provider app_dir + tmp-dir test; fresh-tree smoke | `9f5fd80` (lane layer: priv/test_lanes.exs + mix.exs atomic pair + contract test + fixture + importer split), `b1a9599` (seed_provider task + test), `7d913f8` (DATABASE_URL + test), `ce2eebf` (drops `:nightly`, keeps `:full_catalog :slow`, timeout 120_000, comment rewritten), `8560e90` (landing.log + fresh-tree-smoke.log). `real_catalog_importer_test.exs:149` asserts `== first_import_runs` with "second pass reuses the run" comment; `importer.ex` uses `Application.app_dir`; test writes dataset to `System.tmp_dir!()`; task test asserts 1 run → 2 runs across invocations. Working tree clean. | ✅ PASS |
| 2 | Harness `--only lanes` (5 gates), test.full `--slowest 50`, test.nightly gate, coveralls `--include nightly`, per-file aggregation | `dfdac03`; `measure_gates.sh:88-94` (mode), `:232` (test.full --slowest 50), `:236` (coveralls --include nightly), `:240` (test.nightly), `:244-282` (3-log aggregation); baseline-lanes.json from a real run (5 gates green, error null). | ✅ PASS |
| 3 | BEFORE measurement + shape-check isolation | `96882bc`; `lanes-before.json` (test.full 1,138,814ms / test.nightly 186,779ms, error null) + `lanes-before-summary.json` (top5 dominated by real_catalog_importer_test.exs 410,650ms + importer_provider_test.exs 190,896ms; shape_check_ms 858/538/720; `derived_from: baseline-lanes.json` transparently recorded). | ✅ PASS |
| 4 | Lane contract tests RED, pre-existing green | `4b02ab6`; `artifacts/qa/wi2/contract-red.log` shows exactly the 3 new failures (nightly_tags KeyError; coverage `--include nightly` missing; full-suite `--exclude nightly` present) while pre-existing assertions (CI jobs, fast-lane excludes, alias existence) stay green. | ✅ PASS |
| 5 | Mechanism GREEN: test_helper exclude via priv/test_lanes.exs; `--only nightly` = exactly 2; test.full runs 0 nightly | `2452e9f` + `10a944b` + `bdbf34b`. test_helper.exs now `Code.eval_file(...) |> elem(0)` + `ExUnit.start(exclude: lanes.nightly_tags)`; nightly_tags `[:nightly]` in test_lanes.exs. Recorded deviation: include-priority meant test.full still matched monsters → `10a944b` stripped `:full_catalog :slow` from both monsters (keeping `:nightly`), membership re-proven (19 tests / 2 excluded on bare & full-lane sim; `--only nightly` = 2, 514 excluded); `bdbf34b` fixes the SeedProviderTaskTest corpus-contamination flake (`@moduletag :reset_committed_catalog`, flake-fix.log). | ✅ PASS |
| 6 | CI cutover: deep.yml zero `--exclude nightly` / one `--include nightly` / no pull_request; Makefile + harness flags | `58bf9dd`; current greps: deep.yml `--include nightly` exactly 1 (line 506), zero `--exclude nightly`, `on:` = push/workflow_dispatch/schedule (no pull_request); Makefile:44 `--include nightly`; measure_gates.sh:236; dev_environment_ci + mix_alias contract tests 15/0 green (ci-cutover.log); atomicity (Finding 16b) recorded — mechanism + cutover form one push set. | ✅ PASS |
| 7 | Docs locks: test/AGENTS TAG row + lane paragraph, root AGENTS NOTES, README reword, CHANGELOG | `db613c4`; test/AGENTS.md:25 `:nightly` row + nightly_tags ownership paragraph; AGENTS.md:120-121 lane bullets; README.md:77 reworded line; CHANGELOG entry; docs/production-readiness.md has no lane references (checked, correctly skipped); locked strings preserved (docs_qa_pack + no_scope_creep green in docs-green.log). | ✅ PASS |
| 8 | Membership QA + post-WI1 measurement | `33558f6`; membership.log: `--only nightly` ran exactly the 2 monster names (516/0/514 excluded); full-lane sim 19/0/2 excluded; `lanes-after-wi1.json` test.full 344,874ms (3–6 min expected — in range), test.nightly 537,497ms, 0 failures, 5 gates passed. | ✅ PASS |
| 9 | Spike GO/NO-GO with all 6 criteria + PG-version + nil-key hazard records | `31e9f72`; scratch `bulk_spike_test.exs` (402 lines) + `bulk-spike.json` (all criteria pass: c1 no ArgumentError, c2 rerun 250→250, c3 stable id/title, c4 rollback 0/50 persisted, c5 sandbox clean, c6 ratio 6.1/6.7/6.4); `spike-decision.md` verdict **GO** with criterion-6 adjudication (6.3–6.4x measured vs literal 10x; conservative floor reasoning + budget fit; per plan protocol "assert ratio >= 10 OR record the measured ratio"); PG17 MERGE divergence + contribution nil-key hazard + intra-batch PG 21000 findings recorded. | ✅ PASS |
| 10 | Bulk rewrite: two-phase pipeline, per-resource upsert_identity, minimal `{:replace, identity_keys}`, never `:replace_all`, batch 100, transaction per dataset; nightly 537s→158s | `24d9da8`; `importer.ex` `bulk_upsert!` (L850-868) carries exactly the planned option set; per-table writers use `:unique_slug` / `:unique_publisher_slug` / `:unique_identifier` / etc. with `{:replace, identity_keys}`; `:replace_all` appears only in "NEVER `:replace_all`" docs; seed! (L97-105) and seed_provider! share `build_dataset_rows!`/`write_bulk_dataset!`; bulk-seed-green.log shows the failing-first run (19/7) → green (19/0), gate green, and the final nightly run at **158.4s** (was 537s). | ✅ PASS |
| 11 | seed_provider! parity (verification-only) | `e9ec20f`; seed_provider! keeps `Ash.transact(@provider_transaction_resources)`, `transaction_timeout` opt (incl. :infinity), `prune_stale?` opt, rollback (raise inside transact → `{:error, _}`), idempotency, `{:ok, summary}` shape; calls the shared pipeline directly (no double transact). seed-provider-green.log: importer_provider suite, task test, integration lane (520/0), gate green. | ✅ PASS |
| 12 | Bulk contract + envelope tests: 8 tests (batch boundary 101 rows, intra-dataset dup first-wins, reseed idempotency + curation survival, contribution non-nil keys, nil-key rejection) + envelope <300s | `17d47dc` + `eed59b7`; `bulk_spike_test.exs` = 8-test permanent suite (moduletag :slow, comments mark it as plan todos 9+12); envelope test in real_catalog_importer_test.exs:182-207 (`:full_catalog :slow :nightly timeout: 600_000`, seed lock acquired BEFORE timing, `elapsed_ms < 300_000`); measured 162,257.7ms; nightly run 525/0/522 excluded (exactly 3 nightly tests); batch_size 0 probe executed (validation alive; observed RuntimeError wrapping the Spark validation error, documented); `eed59b7` redirects contract timings to bulk-contract-timings.json so wi2 spike evidence stays pristine. | ✅ PASS |
| 13 | Stale-claim sweep zero + doc locks green | `bfca6e3`; live-file grep (193s-870s / 200s-900s / ~4 min / 30-min corpus / "does not run the test alias") = zero matches (only historical `.omo` plan/draft records retain them — the evidence trail, correctly untouched); Makefile comment corrected to "resolves the `test` alias via Mix.Task.run/2"; deep.yml comments rewritten; docs_qa_pack + no_scope_creep green (11/0); gate green. | ✅ PASS |
| 14 | lanes-final.json (test.full 243,911ms ≤ 300,000; test.nightly 151,039ms ≤ 300,000) + coverage 87.1% ≥ 86.1, no adjustment | `648e437`; `lanes-final.json` (5 gates, error null, git_commit bfca6e3); `coverage-final.json` (87.1% vs 86.1 floor, exit 0, `--include nightly` honored, 0 excluded); `SUMMARY.md` full before→WI1→final table; no coveralls.json change (floor not breached, no regression hidden). | ✅ PASS |
| 15 | Conditional fallback NOT TRIGGERED (evidence-only) | `7321fe0`; fallback-not-triggered.log: trigger condition `test_full_ms > 300_000` evaluated against 243,911ms → not triggered; `config/test.exs` grep proves no `committed_catalog_fixture_dir` override; no code changes; affected-test enumeration documented as N/A. | ✅ PASS |

## OUT guardrail verification

| Guardrail | Evidence | Result |
|---|---|---|
| Corpus/manifests/snapshots untouched | `git log --stat 912c0d8..HEAD -- priv/catalog_sources` → **zero commits** | ✅ |
| Cover cache untouched | `-- priv/static/covers` → zero commits | ✅ |
| No dependency additions / Ash upgrade | `mix.exs` deps diff → none; `mix.lock` → zero commits | ✅ |
| No schema migrations | `-- priv/repo/migrations` → zero commits | ✅ |
| No ci.yml / mix gate / test.fast changes | `-- .github/workflows/ci.yml` → zero commits; mix.exs alias composition unchanged (contract-locked) | ✅ |
| No `:id` writability on any resource | No resource/attribute changes outside `real_catalog/importer.ex`; `uuid_primary_key` writable?: false honored (spike finding 5) | ✅ |
| No `:replace_all` | Only in "NEVER `:replace_all`" docs (importer.ex:33, AGENTS.md:37) | ✅ |
| Public contracts / routes / projections unchanged | No lib/hiraeth_web changes, no HEEx/CSS changes in range | ✅ |
| No local `--max-cases` change (D12) | mix.exs aliases carry no --max-cases; serial local default preserved | ✅ |
| deep.yml keeps every job | Diff = 2 run-lines + comments only (17 lines) | ✅ |
| Nothing unrelated discarded (D11) | Working tree clean; DATABASE_URL + seed_provider landed as-is; all evidence committed | ✅ |

## Findings (non-blocking, all recorded by the worker)

1. **Todo 5 deviation (recorded, resolved):** the initial mechanism commit discovered ExUnit include-priority over helper excludes, so `test.full` still ran the monsters; `10a944b` stripped `:full_catalog :slow` from the two monsters and re-proved membership. End state meets the acceptance; the honest mid-flight correction is exactly the evidence the plan asked for.
2. **Spike criterion 6 (adjudicated):** measured 6.3–6.4x, not literal ≥10x. `spike-decision.md` documents real numbers, the sandbox-conservative floor argument, and the load-bearing budget fit — consistent with the plan's own protocol ("assert ratio >= 10 OR record the measured ratio").
3. **Todo 12 probe error-type nuance:** `batch_size: 0` surfaced as a RuntimeError wrapping the Spark validation error rather than a bare ArgumentError; the validation-alive property is proven and documented in bulk-contract-green.log.
4. **lanes-before.json derivation:** derived from the same real run as baseline-lanes.json (byte-identical tree) with the `derived_from` field and raw committed logs — transparent, no fabrication.
5. **Before-state test.full exceeded the plan's soft 5–15 min guess (19 min):** the honest measurement is recorded; the plan's acceptance required a *green* baseline with dominant importer costs, both of which held.

## Conclusion

**APPROVE.** The plan's 15 todos are each satisfied with committed evidence; the OUT guardrails hold; the uncommitted-layer landing matches D11 exactly; decisions D1–D13 (as revised by Metis findings) were honored — including the never-`:replace_all` bulk shape, the no-precomputed-ids rule, the 86.1 coverage floor calibrated on the full suite with `--include nightly`, the full-corpus fixture decision (D3, fallback correctly not triggered), and the atomic test_lanes.exs/mix.exs pairing.

**Evidence paths:** `artifacts/qa/wi1/` (landing, fresh-tree smoke), `artifacts/qa/wi2/` (contract-red, mechanism-green, ci-cutover, docs-green, spike, flake-fix), `artifacts/qa/wi3/membership.log`, `artifacts/qa/wi4/` (bulk-seed-green, bulk-contract-green, seed-provider-green, timings), `artifacts/qa/wi5/` (doc-sync, fallback-not-triggered), `artifacts/qa/perf/` (lanes-before/after-wi1/final JSON, coverage-final.json, SUMMARY.md, committed logs).

*This verdict file is intentionally left UNCOMMITTED for the orchestrator (evidence-only artifact; no product/test/CI code was modified by this review).*
