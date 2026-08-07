# SCRIPTS/QA/INGESTION KNOWLEDGE BASE

## OVERVIEW
Production-grade ingestion drill lane. Two deterministic shell entries replay the ingestion control plane and probe its failure paths, then a FastAPI `TestClient` probe confirms the private sidecar rejects loopback and userinfo URLs. Receipts land under `.omo/evidence/production-grade-ingestion/` so each run leaves a signed, appendable trail.

## STRUCTURE
| File | Owns |
|---|---|
| `production_ingestion_drill.sh` | happy-path shell: starts Postgres, runs drill tags, writes `T25-drill-cleanup.txt` |
| `production_ingestion_drill_test.exs` | ExUnit drill tests tagged `:provider_replay` and `:replay_load_idempotency` |
| `production_ingestion_adversarial.sh` | failure-path shell: runs adversarial tags, invokes sidecar probe, writes `T25-adversarial-cleanup.txt` |
| `production_ingestion_adversarial_test.exs` | ExUnit adversarial tests tagged `:destructive_diff`, `:cover_host_rejection`, `:scheduler_duplicate_prevention` |
| `sidecar_private_host_probe.py` | FastAPI `TestClient` probe exercising `private_host` and `userinfo` cases, exits non-zero on any unsafe disclosure |

## WHERE TO LOOK
| Concern | File |
|---|---|
| Replay from retained snapshot | `production_ingestion_drill_test.exs` `@tag :provider_replay` |
| Bounded replay idempotency | `production_ingestion_drill_test.exs` `@tag :replay_load_idempotency` |
| Destructive diff quarantine + apply block | `production_ingestion_adversarial_test.exs` `@tag :destructive_diff` |
| Cover host allowlist rejection | `production_ingestion_adversarial_test.exs` `@tag :cover_host_rejection` |
| Provider scheduler duplicate prevention | `production_ingestion_adversarial_test.exs` `@tag :scheduler_duplicate_prevention` |
| Sidecar SSRF/private-host rejection | `sidecar_private_host_probe.py` `CASES` tuple |
| Cleanup receipt content | `.omo/evidence/production-grade-ingestion/T25-{drill,adversarial}-cleanup.txt` |
| Shell command ordering contract | `test/hiraeth/ingestion/production_ingestion_script_contract_test.exs` |

## CONVENTIONS
- Drill and adversarial shells invoke `${POSTGRES_HELPER:-scripts/dev/ensure_postgres.sh} start` before any `mix test`, then run `mix test ... --only <tag> --seed 0 --trace`.
- Both shells emit deterministic `RUN <scenario> ::` and `PASS <scenario>` lines so contract tests can grep for ordered command sequences and `set -euo pipefail` fails fast.
- ExUnit `setup` creates per-test scratch under `System.tmp_dir!()` as `hiraeth-t25-{drill,...}-<unique_integer>`, points `:source_snapshot_retention_root` at it, and registers an `on_exit` that `File.rm_rf!`s the root and restores the prior config.
- Cleanup receipts always include `cleanup_timestamp`, `cleanup_scope`, and `leftover_t25_tmp_roots=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'hiraeth-t25-*' ...)` so leftover scratch paths surface immediately.
- The Python probe patches `fetch_router.ADAPTERS["shopify"]` with a sentinel that flips a flag if any adapter ever runs, then restores the original in `finally`; the probe must short-circuit before the adapter fires on every case.
- Adversarial tests `IO.puts("PASS ...")` with the artifact-relevant fields (counts, ids, status, location) so shell stdout is the human-readable ledger alongside the receipt file.

## ANTI-PATTERNS
- Swapping `ensure_postgres.sh` for any docker-managed postgres. `production_ingestion_script_contract_test.exs` refutes every `docker` invocation in the recorded command log; devenv owns local postgres.
- Reordering `pg_isready` ahead of `devenv up -d hiraeth-postgres`, or running `mix test` before readiness succeeds. The contract test enforces strict command order.
- Returning 200, returning any code other than `invalid_host`, or executing the sentinel adapter inside `sidecar_private_host_probe.py`; any of these makes the probe non-zero and the adversarial shell fails closed.
- Allowing `127.0.0.1`, `probe-user`, `SECRET_TOKEN`, `SECRET_PASSWORD`, full probe URLs, or query strings like `password=`/`token=` to leak into the response body; the probe denies every substring in its `DENYLIST`.
- Skipping the `on_exit` retention-root cleanup so `System.tmp_dir!/hiraeth-t25-*` paths linger; the cleanup receipt's `leftover_t25_tmp_roots` counter must read `0` on success.
- Promoting these shells into the fast gate (`mix gate`); replay/idempotency/adversarial paths are intentionally outside the under-60s developer budget.