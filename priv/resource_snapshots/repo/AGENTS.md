# ASH GENERATOR SNAPSHOTS (priv/resource_snapshots/repo)

## OVERVIEW
This directory is checked-in Ash generator state for the Ash/AshPostgres data layer, not runtime data and not provider evidence. The word "snapshot" appears in three different places across `priv/`, and confusing them is a common hazard. Before reading further, disambiguate them:

- **(1) Ash generator metadata** (this directory). `mix ash_postgres.generate_schemas` and `mix ash_postgres.generate_migrations` write one timestamped JSON per Ash resource plus an `extensions.json` baseline. Replaying against these produces new diffs and migrations.
- **(2) `SourceSnapshot` ingestion rows** (database). `Hiraeth.Ingestion.SourceSnapshot` records, recorded by `ProviderIngestionWorker`, track which provider payload was captured for a given source/import run. These live as Ash rows, not as files here.
- **(3) Raw retained provider artifacts** under `priv/source_snapshots/source-snapshots/`. Immutable fetch payloads used for replay/audit. See the parent `priv/AGENTS.md` for that area.

Only concept (1) belongs in this directory. Concepts (2) and (3) belong to ingestion/provenance flows and are governed elsewhere.

## STRUCTURE
- 22 entries total: one subdirectory per Ash resource plus a top-level `extensions.json` baseline.
- Each subdirectory holds one or more JSON files named `YYYYMMDDhhmmss.json`; the timestamp is the generator run that produced the snapshot.
- Newer files in a given resource directory reflect later schema shapes; older files are retained as a history of Ash-driven shape evolution.
- `extensions.json` pins the generator baseline: installed Postgres extensions (currently `ash-functions` and `citext`) and the `ash_functions_version` against which snapshots were generated.

## WHERE TO LOOK
- Drift or shape questions on a specific resource: read the latest `*.json` inside that resource's subdirectory.
- Generator baseline or extension set: read `extensions.json` next to the subdirectories.
- Migration ledger and `mix ecto.gen.migration` history: see the sibling `priv/repo/migrations/AGENTS.md`.
- Approved 23-provider corpus authority (the publisher-catalog topology these resources describe): `priv/catalog_sources/real_publishers/source_authority_manifest.json`.
- Live database state, provider runs, and `SourceSnapshot` rows: Ash resources under `lib/hiraeth/`, not this directory.

## CONVENTIONS
- These JSON files are generator inputs. Treat them as the canonical "what Ash saw last" record for each resource; new generator runs append, never rewrite.
- Snapshots describe Ash resource shape (attributes, relationships, identities, aggregates, action-shaped metadata). They are not table rows and not seed data.
- Keep `extensions.json` in lockstep with the Postgres extensions installed by migrations; if you add `pg_trgm`, `pgcrypto`, etc., update both the extension migration and this baseline.
- Run `mix ash_postgres.generate_schemas` after adding or rewriting a resource so the resource's snapshot directory catches up.
- Handwritten migrations under `priv/repo/migrations/` are the source of truth for schema; these snapshots exist so future generator runs diff against a known shape instead of starting blind.

## ANTI-PATTERNS
- **Re-running `mix ash_postgres.generate_migrations` blindly.** Existing checked-in snapshots stop well before the current Ash resources and migrations, and a naive re-run can rediscover tables that already have hand-written migrations or mis-diff them. Always regenerate with intent and review the diff against `priv/repo/migrations/`.
- Hand-editing `*.json` snapshot files to "match" current code. Update the Ash resource and regenerate; the JSON is derived state.
- Treating snapshots as runtime data, fixtures, or sample rows. They describe shape only.
- Deleting older `YYYYMMDDhhmmss.json` files to "tidy up" the directory. They are the diff history for the resource.
- Letting `extensions.json` drift from the actual Postgres extension set. Stale baselines produce diffs that look real but aren't.
- Importing concepts (2) or (3) into this directory. `SourceSnapshot` rows and raw provider payloads have their own governed homes; mixing them here breaks provenance.
