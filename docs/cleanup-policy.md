# Repository Cleanup Policy

Hiraeth cleanup is allowlist-only. Cleanup tasks may remove only named,
reproducible local artifacts after recording evidence for what will be removed.
They must never use blanket repository cleaning commands as a shortcut.

## Never-cover-cache rule

Never delete, clean, modify, truncate, move, or regenerate the root
`priv/static/covers/cache/*` cover cache as part of repository cleanup. Preserve
both `priv/static/covers/cache/.gitkeep` and existing generated cover files.

Cover files are product-visible, provenance-sensitive, and potentially expensive
to reproduce. Commands that might write covers must run through
`scripts/qa/cover_cache_sandbox.sh`, which snapshots recursive SHA-256 hashes
for the root cache, compares them with the Todo 1 receipt, runs the requested
command in a temporary repository copy that excludes the root cache, and compares
the root cache unchanged afterward.

Long-running sandbox commands should be bounded by the caller. For evidence
probes or other quick checks, set `COVER_CACHE_SANDBOX_TIMEOUT` to a coreutils
`timeout` duration such as `5s`; the helper then uses `timeout` for the child
command and still performs root cover-cache hash comparison before and after the
sandboxed run. When the variable is unset, the helper intentionally propagates
the child command without imposing a default timeout so normal operator commands
retain their native runtime behavior and exit status.

## Deletion allowlist

Cleanup deletion is limited to this exact list of reproducible local artifacts:

- `artifacts/`
- `_build/`
- `deps/`
- `.mypy_cache/`
- `.pytest_cache/`
- `.ruff_cache/`
- `sidecar/.venv/`
- `sidecar/.pytest_cache/`
- `scripts/__pycache__/`
- `scripts/catalog/__pycache__/`
- `scripts/qa/ingestion/__pycache__/`
- `erl_crash.dump`

This list is intentionally identical to the cleanup execution allowlist used by
Todo 3 and by `scripts/qa/cover_cache_sandbox.sh`. Do not substitute patterns
such as "Python cache directories" or broaden it to parent directories. If an
allowlisted path is absent, record `missing	<path>` in the cleanup receipt
instead of broadening the deletion scope.

## Deletion denylist

Cleanup must not delete or rewrite source, provenance, contracts, plans, or
operator evidence:

- `priv/static/covers/cache/*` — the exact never-cover-cache rule above.
- `lib/`, `test/`, `config/`, `assets/`, `priv/catalog_sources/`, and other
  source-controlled product files.
- `.omo/` and `.omx/` unless a later task names a precise evidence artifact.
- `.git/`, `mix.exs`, `mix.lock`, `README.md`, `docs/`, and `Makefile`.

When in doubt, preserve the path and add a follow-up note rather than deleting.

## Named exceptions (production readiness plan)

The production-readiness cleanup plan (Wave 3, TODOs 14-18) authorizes exactly
four named moves that fall outside the allowlist/denylist above. Each is a
single, evidence-backed deletion or archival move executed by its own TODO; this
section is the policy authorization for them and nothing else:

1. `worklog.md` → `docs/history/worklog-2026-06.md` (TODO 15): archival move of
   the dated worklog into the history directory so the repository root stays
   clean.
2. `priv/repo/structure.sql` → add to `.gitignore` (TODO 16): the file is an
   untracked local `pg_dump` artifact that is neither governed nor referenced.
3. Makefile `bootstrap-check`/`qa-pack` `.omo`-dependency removal (TODO 17):
   drop the `.omo/plans/hiraeth-bootstrap.md` dependency from those two targets
   so operator targets do not depend on workspace state.
4. Makefile `test-ingest` fake-JUnit removal (TODO 18): remove the fabricated
   `<testsuite>` report that does not reflect real test output.

These exceptions do not broaden the deletion allowlist or denylist above, and
they do not weaken the never-cover-cache rule. Any further deletion or move
requires a new named exception.
