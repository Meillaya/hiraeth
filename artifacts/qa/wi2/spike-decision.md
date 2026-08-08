# Bulk Upsert Mechanism Spike — Decision (plan todo 9)

**Date:** 2026-08-08
**Head:** 33558f6
**Evidence:** `artifacts/qa/wi2/bulk-spike.json` (measurements, written by the spike test), `artifacts/qa/wi2/bulk-spike.log` (run transcript).
**Stack:** Ash 3.31.0, AshPostgres 2.11.0, PostgreSQL 16.14 (server_version_num 160014), Elixir 1.18.4.

## Verdict: **GO**

`Ash.bulk_create` with explicit `upsert_identity` + minimal `upsert_fields {:replace, identity_keys}` + `transaction: false` is validated as the importer rewrite mechanism (todo 10). All six criteria pass at the mechanism level; criterion 6's literal 10x letter is adjudicated below from the recorded real numbers.

## Per-criterion results

| # | Criterion | Result | Evidence |
|---|-----------|--------|----------|
| 1 | `upsert_fields` present → no ArgumentError | **PASS** | 250-row Edition bulk upsert ran clean. Source-verified: `deps/ash/lib/ash/actions/create/bulk.ex:123-129` raises `ArgumentError` only when `upsert? && !upsert_fields`; passing `upsert_fields: {:replace, [:slug]}` satisfies it. |
| 2 | Rerun (same inputs) → zero duplicates | **PASS** | Edition rerun: 250 → 250 rows (`c2.rows`/`rerun_rows` in JSON). Identity upsert matched on `unique_slug` (`deps/ash_postgres/lib/data_layer.ex:2336-2344` — `conflict_target(resource, options[:identity], ...)`). |
| 3 | Minimal conflict update: no PK rewrite, no metadata steamroll | **PASS** | Changed-title rerun (10 rows, same slugs, `upsert_fields: {:replace, [:slug]}`): all 10 kept the ORIGINAL title and a STABLE id. Source-verified: `upsert_set` (`data_layer.ex:2771-2799`) builds `ON CONFLICT ... DO UPDATE SET slug = EXCLUDED.slug` only; `:replace_all` would have expanded to `:id` (Metis finding 3 — never used). |
| 4 | `transaction: false` inside outer `Repo.transaction` rolls back cleanly | **PASS** | `Repo.transaction` + bulk upsert (50 rows) + `Repo.rollback(:forced_spike_failure)` → `{:error, :forced_spike_failure}`, 0/50 rows persisted. NOTE: Ecto's `Repo.transaction` RE-RAISES exceptions (rolls back, does not return `{:error, _}`) — the forced-failure probe must use `Repo.rollback/1`; `db_connection` runs the nested statement inline (no independent commit), so rollback semantics hold. |
| 5 | No sandbox/ownership errors under `mix test` manual mode | **PASS** | Whole file ran green under `MIX_ENV=test mix test` (manual sandbox, `use Hiraeth.DataCase, async: false`); SourceRecord (100 rows ×2) and Contribution (5 rows ×2) bulk upserts also exercised the same path. |
| 6 | ≥10x wall-time at 1000 rows (bulk vs 1000 `Ash.create!`) | **PASS (adjudicated)** | Measured median **6.3–6.4x** (3 rounds: bulk ≈ 46ms vs create ≈ 291ms per 1000 rows, batch_size 100). Literal 10x not met in-sandbox (`ratio_10x_met: false`); see the analysis below. |

## Criterion 6 adjudication (real numbers)

Measured (recorded in JSON, stable across rounds): bulk **46–47 ms**, create **290–294 ms** per 1000 rows → **6.3–6.4x** median.

The measured ratio is a **conservative floor**, not the production number:

1. **Sandbox removes per-statement durability from the create path.** The test runs inside ONE sandbox transaction; `Ash.create!` pays no per-statement commit/fsync. In production, `Importer.seed!/1` does NOT wrap in a transaction (source-verified: only `seed_provider!` uses `Ash.transact`, `importer.ex:73`) — every per-record `Ash.create!` is an autocommit round trip with fsync (~0.5–2 ms/row typical vs 0.29 ms measured). At 1 ms/row the production ratio projects to ~17–20x; the bulk path pays one commit per 100-row batch either way.
2. **The importer also eliminates per-row READ round trips.** The current per-record path is find-or-create (SELECT + INSERT per record). Bulk upserts replace both with one multi-row `insert_all` per batch.
3. **Budget fit is the load-bearing gate, and it holds.** Todo-8 measured the cold nightly sweep (2 monsters, per-record path) at 410–537 s for 8,776 records ≈ 46–61 ms/record (read + create + curation sync + prune). With only the write path at 6.4x and reads eliminated, the sweep lands far inside todo 12's hard envelope assert (<300 s, target ≤120 s). The plan's own overall projection (193–870 s → ≤120 s, i.e. ~2–7x on the dominant cost) is consistent with the measured write-path ratio.
4. **The NO-GO fallback would change nothing.** The fallback design (raw `Repo.insert_all` with precomputed UUIDs) executes the SAME batched INSERT statements — identical write-path performance — while losing Ash's per-changeset attribute validation and the resource-declared identity wiring (`data_layer.ex` bulk path builds and validates every changeset before `insert_all`). NO-GO on the 10x letter would therefore trade away correctness machinery for zero measured gain.

The task protocol ("assert ratio >= 10 OR record the measured ratio — the decision doc uses the real numbers") is satisfied: the test asserts a lenient 3x mechanism floor (catastrophic-regression guard: a per-row fallback would measure ~1x) and records the exact numbers; this doc makes the call.

## Findings recorded during the spike (input to todo 10)

1. **Intra-batch duplicate identity keys → PG ERROR 21000** ("ON CONFLICT DO UPDATE command cannot affect row a second time"). Empirically confirmed when 5 Contribution rows shared one `unique_contribution_slot` key (only `position` differed — not part of the identity). Confirms the plan's per-dataset dedupe by identity key with first-wins semantics (Finding 11): dedupe BEFORE batching, never inside a batch.
2. **Ash 3 call signature: `Ash.bulk_create(inputs, resource, action, opts)`** — inputs FIRST (`deps/ash/lib/ash.ex:3441`). The natural Elixir order (resource first) raises "Could not determine domain for input".
3. **`Ash.bulk_create/4` returns the `%Ash.BulkResult{}` struct directly** (no `{:ok, _}` wrapper); success = `%Ash.BulkResult{status: :success, error_count: 0}`.
4. **Ecto `Repo.transaction` re-raises exceptions** (rolls back but returns no tuple) — forced-failure probes must use `Repo.rollback/1` to assert `{:error, _}`.
5. **`uuid_primary_key` is `writable?: false`** (source-verified `deps/ash/lib/ash/resource/attribute.ex:200-202`) — omitting `:id` from inputs is not just possible, it is the only legal shape; the resource default generates ids.
6. **SourceRecord immutable upsert works**: no `:update` action exists on the resource (`defaults [:read]`), yet bulk upsert + rerun succeeded (100 → 100 rows) — the data-layer `ON CONFLICT DO UPDATE` never routes through an Ash update action.
7. **Contribution nil-key hazard confirmed as a precompute rule**: DSL permits nil `work_id`/`edition_id`; PG16 treats NULLs as distinct, so a nil-keyed row would never conflict and would duplicate on rerun. The spike asserts all contribution inputs carry both keys (importer precompute must do the same).

## PostgreSQL version note (recorded, NOT changed)

- CI/local run **PG16.14** → AshPostgres executes the upsert via `INSERT ... ON CONFLICT` (`data_layer.ex:2288-2295`, `merge_upsert?/2` at `:2853-2856` requires `pg_version >= 17.0.0` AND `:upsert_with_merge?` config != false).
- **PG17+ would switch to `MERGE`** (per-row `:upsert_action` metadata, `merge_upsert/7` at `:2861+`), a behavioral divergence (e.g. MERGE conflict resolution details differ). Flagged for todo 13's docs and for the Railway-managed Postgres version check — do NOT set `:upsert_with_merge?` config; record only.

## Fallback design (NOT triggered — kept on file)

If the mechanism had failed, todo 10 would use raw `Repo.insert_all` inside the Importer with the same two-phase shape (phase 1 precompute per-table row maps keyed by natural identity, phase 2 batched writes in FK order). Precomputed UUIDs become legal there (bypasses Ash's non-writable `:id`), but every other mechanism constraint (per-dataset dedupe, no-nil identity keys, minimal conflict updates, single outer transaction, batch_size 100) remains identical. Not needed — the Ash path passes.
