# REPO MIGRATIONS KNOWLEDGE BASE

## OVERVIEW
The checked-in Ecto/Ash migration ledger for `Hiraeth.Repo`. Mix-generated Ecto migrations and Ash-generated resource migrations coexist in a single forward-only chain. The Ash migration generator currently sees a stale baseline snapshot under `priv/resource_snapshots/repo`, so the manual `mix ecto.gen.migration` lane is the trusted authoring path. Inherits scope rules from `../../AGENTS.md` and `../AGENTS.md`; this file specializes generation, naming, and rollback review.

## STRUCTURE
19 Ecto migration files plus this `AGENTS.md` (20 entries total). Filenames are 14-digit UTC timestamps (`YYYYMMDDHHMMSS`) followed by a snake_case slug. Modules live under `Hiraeth.Repo.Migrations` in CamelCase, one module per file. Shape:

- a pair of 1-second-apart initial files: `_initial_resources_extensions_1.exs` (extensions, including `pg_trgm`) followed immediately by `_initial_resources.exs` (core domain tables)
- Ash-generated resource snapshots covering `Catalog`, `Sources`, `Covers`, and `Ingestion`
- handwritten delta migrations for indexes, Oban, control-plane fields, retention metadata, source-snapshot backreferences, and removal of accounts/auth tables

## WHERE TO LOOK
| Need | Location |
|---|---|
| Author a new migration | run `mix ecto.gen.migration <snake_case_name>` from repo root, then edit the generated file |
| Verify table/index contract | `test/hiraeth/ash_postgres_migration_test.exs` (lists every required table and every public-catalog index) |
| Inspect Ash baseline snapshot | `priv/resource_snapshots/repo/` (treat as read-only evidence; do not regenerate) |
| Run migrations | `mix ash.migrate` for dev, `MIX_ENV=test mix ash.migrate` for test, `mix ecto.migrate` for the Ecto-only path |
| Oban schema control | `add_oban_jobs_table.exs`; `Oban.Migration.up(version: 14)` / `down(version: 1)` |

## CONVENTIONS
- Use `mix ecto.gen.migration migration_name_using_underscores` as the manual authoring lane. Do not invoke the Ash auto-migration generator against the current snapshot; its baseline is stale and will re-emit or misorder already-applied DDL.
- Modules are CamelCase under `Hiraeth.Repo.Migrations.*`. The file slug mirrors the module tail.
- 14-digit timestamp filenames, lexicographically sortable and chronological. Keep the timestamp ordering consistent with the surrounding chain; never rename an applied migration.
- UUID primary keys via `fragment("gen_random_uuid()")` or the Ash equivalent. Never serialize sequential ids.
- Default to `change/0` for additive work. Use explicit `up/0` + `down/0` whenever the operation is asymmetric: data backfill, constraint relax/tighten, drop-and-replace, or Oban `up(version: N)` paired with `down(version: 1)`.
- Naming conventions for constraints and indexes: `<table>_unique_<identity>_index` for unique indexes, `<table>_<column>_fkey` for foreign keys, `<table>_public_catalog_<purpose>_index` for the typed public-catalog projection. Every new index name must be registered in `ash_postgres_migration_test.exs`.
- Oban delegates schema control to the upstream library via `Oban.Migration.up(version: 14)` and `Oban.Migration.down(version: 1)`. Bump the version constant only when Oban ships a schema change.
- Extensions, notably `pg_trgm`, are created in the extensions-first migration and must persist across all subsequent rollbacks. Search-rollback migrations drop their trgm indexes but never `DROP EXTENSION pg_trgm`.

## ANTI-PATTERNS
- Re-running the Ash auto-migration generator against the current `priv/resource_snapshots/repo` baseline. The snapshot is stale and will re-emit applied DDL.
- Removing or renaming an applied migration. The chain is forward-only on deployed environments; corrections ship as a new migration.
- Shipping asymmetric rollback paths without deployment review. `remove_accounts_auth_tables.exs` deliberately returns `:ok` from `down/0` because the data path is destructive; any reversal requires a fresh restoration migration, not a downgrade.
- Adding a public-catalog index whose name is not registered in `test/hiraeth/ash_postgres_migration_test.exs`. That contract test is the authoritative table/index registry.
- Dropping the `pg_trgm` extension in any rollback. Search indexes depend on it; the extension stays even when individual trgm indexes are removed.
- Mixing `change/0` and explicit `up/0`+`down/0` in a single module. Pick the style that matches the operation and keep it consistent inside the file.
- Pulling domain logic, ingestion flow, cover cache handling, or source-snapshot lifecycle code into migrations. Migrations own schema only.
- Treating sibling `priv/repo/structure.sql` as governed schema state. It is an untracked local pg_dump artifact referenced by nothing; commit it deliberately or gitignore it.