# F2 Verdict — Code-Quality Review

**Plan:** `.omo/plans/test-full-and-bulk-nightly-seed.md`
**Reviewer:** F2 code-quality reviewer
**Date:** 2026-08-08
**Scope:** `mix gate` green; importer rewrite conventions (trusted-writer confinement, no policy constants outside SourcePolicy, raw SQL only where precedent exists, no `:id` writability); no new deps; HEEx/Tailwind untouched; both contract tests lock every mechanic; new-test quality.

## VERDICT: APPROVE (issued after F2-1 fix + full re-verification)

> Initial review returned **REJECT** on one blocking finding (F2-1, below). The fix was applied and every re-verification step passed (see "Re-verification after fix" section and `artifacts/qa/final/F2-fix.log`). F2 now APPROVES; remaining items are non-blocking follow-ups.

### Re-verification after fix (2026-08-08, commit `b89b5aa`)

Fix applied: `test/hiraeth/real_catalog_importer_test.exs:178-181` — removed `@tag :full_catalog` + `@tag :slow` from the perf-envelope test, keeping `@tag :nightly` + `@tag timeout: 600_000` (exactly the 10a944b monster precedent); comment updated to document the include-wins trap. Evidence: `artifacts/qa/final/F2-fix.log`.

1. **Membership (test.full shape):** `MIX_ENV=test mix test --include full_catalog --include slow test/hiraeth/real_catalog_importer_test.exs --trace` → envelope shows `(excluded)`; duration-anchored grep `"completes within the 300s perf envelope" ([0-9]` → **0 matches**; 13 tests, 0 failures, 2 excluded. "ZERO nightly-tagged tests in test.full" now holds.
2. **Nightly lane:** `MIX_ENV=test mix test --only nightly --trace` → **exactly 3 tests ran, 0 failures** (525 total, 522 excluded): envelope 178,485.2ms, full-corpus monster 178,935.2ms, seed_provider! monster 182,959.2ms. All three well under the 300s envelope assert.
3. **`mix gate`:** exit 0, 15.7s wall, 525 tests / 0 failures / 116 excluded; no new warnings vs pre-fix gate.
4. **Format:** `mix format` applied; `mix format --check-formatted` clean.
5. **Contract locks:** `mix_alias_contract_test.exs` + `dev_environment_ci_contract_test.exs` → 15 tests, 0 failures.
6. **Tag membership:** anchored `grep -rn "^\s*@tag :nightly" test/` → **exactly 3 hits in 2 files** (importer_provider_test.exs:203, real_catalog_importer_test.exs:158 + :182).

Expected side effect (confirmed): test.full no longer carries the envelope's ~100-200s full-corpus seed; the 243,911ms lanes-final measurement drops accordingly, restoring real headroom under the 300s budget.

---

## Blocking finding (resolved)

### F2-1 — Envelope test runs inside `mix test.full`; `:nightly` membership contract is broken

**What happens:** `mix.exs` builds `"test.full": ["test #{include_args()}"]` → `mix test --include slow --include full_catalog --include integration --include performance --include browser --include public_catalog_full`. ExUnit's filter gives include precedence over exclude (`ExUnit.Filters.eval` checks include first — verified in installed source `/nix/store/b67xs9l29a7q3m4vpm3ca4m9bw91zx8n-elixir-1.18.4/lib/elixir/lib/ex_unit/lib/ex_unit/filters.ex`), and `Mix.Tasks.Test` re-applies CLI includes *after* the helper's `ExUnit.start(exclude: [:nightly])` (same store, `lib/elixir/lib/mix/lib/mix/tasks/test.ex:616`). Any test tagged with both `:nightly` and a `slow_tags` tag therefore runs in `test.full`. The perf-envelope test is exactly that shape: `test/hiraeth/real_catalog_importer_test.exs:178-181` — `@tag :full_catalog @tag :slow @tag :nightly @tag timeout: 600_000`.

**Evidence (the plan's own recorded runs):**
- `artifacts/qa/perf/logs/test.full.log:842` — `* test bulk full-corpus seed completes within the 300s perf envelope (Hiraeth.RealCatalogImporterTest) (101783.1ms)` ran inside the `test.full` gate of the final `lanes` measurement. The two monsters were correctly excluded (`test.full.log:269` shows `(excluded)` for the monster), but the envelope ran: it is 101.8s — ~42% — of the 243,911ms `test.full` total in `artifacts/qa/perf/lanes-final.json`.
- `test/hiraeth/mix_alias_contract_test.exs:109-112` asserts the opposite of observed reality: "`ExUnit.Filters` checks includes before excludes, so `--include nightly` opts the lane back in from any default; without that flag, `:nightly` must never run. This holds in bare mix test, test.fast, test.full, and coveralls alike." — false for `test.full`.
- Independent probe (Elixir 1.18.4, single-call `ExUnit.configure(include: [:slow], exclude: [:nightly])`): a `@tag :nightly @tag :slow` test **runs**; the same shape with no include does not. Include wins; the leak is structural, not a flake.
- The plan itself knew this hazard: commit `10a944b` ("restrict corpus monsters to the :nightly lane tag") fixed the *monsters* by tagging them `:nightly`-only; the envelope (commit `17d47dc`) reintroduced the multi-tag shape. F3's acceptance lists only the two monster names for the "ZERO nightly-tagged" grep (`artifacts/qa/wi3/membership.log` greps lines), so the leak would ship silently.

**Impact:** every local `mix test.full` and every deep.yml `full-suite` partition (`.github/workflows/deep.yml:294` runs `mix test.full --max-cases 8 --partitions 3`) silently performs a destructive `clear_catalog!()` + full 8,776-record corpus seed (~100–200s, DB churn under the `:global` seed lock). On this 16-core box `test.full` still fits the 300s budget (244s) but with only ~56s headroom; on a 2-core CI box the envelope's own `<300s` assert becomes a `test.full` gate — turning the opt-in nightly lane into a blocking concern for the full suite, and contradicting the plan's own 5-minute criterion.

**Recommended fix (either; both keep all contract tests green):**
1. **Primary (surgical, follows the 10a944b precedent):** drop `@tag :full_catalog @tag :slow` from the envelope at `real_catalog_importer_test.exs:178-180`, leaving `:nightly` + `timeout`. The envelope remains in `mix test --only nightly` and in `mix coveralls --include nightly` (coverage floor unchanged), and stops running in `test.full`.
2. **Alternative:** restore `"test.full": ["test"]` in `mix.exs` (the `--include slow_tags` flags are redundant — plain `test` already runs everything minus the helper-excluded `:nightly`; nothing in `mix_alias_contract_test.exs` asserts them, only that `test.full` starts with `test` and contains no `--exclude`).

Follow-up hardening: add a membership assertion (e.g., assert no `@tag :nightly` test also carries a `slow_tags` tag, or assert the `test.full` alias carries no `--include`) to `mix_alias_contract_test.exs` so this class of leak is locked, not just the config.

---

## Verified clean (evidence paths)

| F2 criterion | Result | Evidence |
|---|---|---|
| `mix gate` green | ✅ exit 0, **16.3s wall** on this box (compile `--warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `credo --strict` 69 checks / 0 issues, `test.fast` 525 tests / 0 failures / 116 excluded) | `/tmp/opencode/gate.log` (rerun); commit-adjacent run `artifacts/qa/perf/logs/test.fast.log` |
| Trusted-writer confinement | ✅ all writes via `Ash.bulk_create`/`create!` with `authorize?: false` inside the validator-gated Importer; the only `Repo` usage in `lib/` is the **pre-existing** `prune_stale_source_records!` raw SQL (3 `Repo.query!`, `importer.ex:1211-1250`; present unchanged at `9f5fd80:803-830`); `public_catalog.ex` Repo usage is pre-existing reads | `git grep Repo` over `lib/`; `git show 9f5fd80:lib/hiraeth/real_catalog/importer.ex` |
| No policy constants outside SourcePolicy | ✅ plan range adds none; importer has no host/path allowlists (only cache keys, timeout, transaction-resource list) | `git diff 9f5fd80..HEAD -- lib/` grep `@cover_hosts|@source_hosts|@source_path|@required_gate|@provider_gates` → 0 hits |
| No `:id` writability changes | ✅ zero resource files touched in plan range; all 15+ resources still `uuid_primary_key :id`; no `writable? true` on any id; no bulk input carries `:id` | `git diff --name-only 9f5fd80..HEAD -- lib/hiraeth/{catalog,sources,covers}` (empty); greps; full-file read |
| No `upsert_fields: :replace_all` | ✅ zero occurrences in code (only doc prose saying "never `:replace_all`") | `git grep replace_all` |
| `:batch_size` private opt threading | ✅ private `Keyword.get(opts, :batch_size, 100)` in `seed!/2` and `seed_provider!/3`, threaded through `import_dataset!`/`write_bulk_dataset!` into all 11 table writes; public arity unchanged (`seed!/1`, `seed_provider!/3`; `seed!` gained a backward-compatible `opts \\ []`) | `importer.ex:96-126, 148-169, 469-508, 850-889` |
| Error handling | ✅ `assert_bulk_success!` raises on `status: :error` with error detail (`importer.ex:891-897`); an unexpected `BulkResult` shape fails loudly via clause mismatch, never silently; `import_dataset!` re-raises `{:error, reason}`; `seed_provider!` preserves the `{:ok, _} | {:error, _}` contract with rescue path | `importer.ex:148-169, 891-897` |
| Dead code (lib) | ✅ `import_record!` gone; no orphaned lib helpers; kept helpers all referenced | `git grep import_record!` (0 hits); full-file read |
| Credo clean | ✅ part of `mix gate` (`--strict`, 69 checks, no issues) | gate log |
| No new deps | ✅ `mix.exs` deps block byte-identical vs `9f5fd80^`; only alias assembly changed | `git diff 9f5fd80^ HEAD -- mix.exs` |
| HEEx/Tailwind untouched | ✅ zero `*.heex` / `assets/css` / `*.css` changes in plan range | `git diff --name-only 9f5fd80..HEAD` |
| Contract tests lock mechanics | ⚠️ both run green (15 tests, 0 failures) and lock the *configuration* (nightly_tags, helper exclude wiring, deep.yml `--include nightly` / no `--exclude nightly`, no pull_request trigger), but the behavioral membership claim in `mix_alias_contract_test.exs:109-112` is disproven by recorded evidence → F2-1 | `mix test test/hiraeth/mix_alias_contract_test.exs test/hiraeth/dev_environment_ci_contract_test.exs` (15/15 green) |
| New-test quality | ✅ real behavior, not mock-mirrors: 101-row batch boundary incl. `batch_size: 0` rejection; duplicate-ISBN first-wins via `seed_provider!`; reseed idempotency at a batch edge + curated-description survival (`source_safe_work_update?`); nil-keyed contribution rejection; rollback-on-partial-failure asserting zero rows across 7 tables; conflict-upsert locks id stability + no title steamroll; envelope times with `:global` lock acquired **before** timing; spike evidence honest (6.4x ratio, 10x unmet, adjudicated in `spike-decision.md`) | `test/hiraeth/real_catalog/bulk_spike_test.exs` (680 lines), `importer_provider_test.exs:89-123`, `real_catalog_importer_test.exs:182-202` |

---

## Non-blocking follow-ups

- **F2-2 — Dead code in the touched test file (plan-owned).** `test/hiraeth/real_catalog_importer_test.exs` carries unused aliases (`Contribution`, `Imprint`, `Series`, `SeriesMembership`, `Repo` — gate-log compile warnings) and an orphaned `provider_record_count/2` helper (line 927) left by the todo-1 split (used at `9f5fd80^`, def-only since `9f5fd80`). Test-env compile warnings don't fail the gate (warnings-as-errors covers `lib/` only), so this is a nit, not a gate issue. The `e2e_ingestion_stealthy_test.exs` unused-alias warning is **not** plan-owned (file untouched in plan range).
- **F2-3 — `artifacts/qa/wi4/bulk-contract-timings.json` drift (known item, confirmed).** The bulk contract suite's `setup_all` `on_exit` calls `write_json!()` unconditionally, rewriting the committed artifact on every `test.full` run (new `head`, new timings). `eed59b7` only redirected the writer away from the wi2 spike file. Tree is currently clean (`648e437` re-committed the fresh copy), but the next `test.full` run dirties it. Recommend gating `write_json!` behind an env var (e.g. `BULK_EVIDENCE=1`) or a gitignored path.
- **F2-4 — Envelope wall variance.** Same envelope measured 49s (nightly lane), 102s (test.full), 162s (`wi4/bulk-contract-green.log`) — the per-seed envelope vs nightly-lane wall distinction is real and machine/contention dependent. The `<300s` assert is loose enough on this box, but combined with F2-1 it is what currently makes the `test.full` budget fragile; fixing F2-1 removes the coupling.
- **F2-5 — Pre-existing rare `test.fast` flake.** Unreproduced, out of plan scope; noted per plan context (`artifacts/qa/wi2/flake-fix.log` records the prior attempt).

## Bottom line

High-quality rewrite: confinement, FK-ordered bulk pipeline, minimal-conflict updates, honest error handling, real behavioral tests, clean gate, no deps, no UI surface touched — all verified. The F2-1 membership leak was confirmed, fixed (commit `b89b5aa`, envelope now `:nightly`-only), and re-verified across all six checks: envelope excluded from `test.full`, nightly lane still exactly 3 tests/0 failures, gate green, format clean, contract locks green, tag membership exactly 3. **F2: APPROVE** — with the non-blocking follow-ups (F2-2 test-file dead code, F2-3 timings drift, F2-4 envelope wall variance, F2-5 pre-existing flake) recommended for cleanup.
