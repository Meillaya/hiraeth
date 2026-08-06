# TEST SUPPORT KNOWLEDGE BASE

## OVERVIEW
ExUnit support harness for fixture ownership, deterministic data, and mock contracts. Inherits tag and base-case rules from `../AGENTS.md`; this file owns nothing else from the parent.

## STRUCTURE
```
test/support/
  data_case.ex, conn_case.ex, query_counting.ex        # root: shared cases + query envelope
  ingestion_fixtures.ex                                 # deterministic Ash builders (fixed ISBN 9781646050001)
  apply_phase_regression_helpers.ex                     # apply-phase regression harness
  deep_vellum_stealthy_fixture.ex                       # Deep Vellum stealthy scenario seed
  mock_deep_vellum_stealthy_sidecar_client.ex           # typed sidecar mock for that scenario
  catalog/
    cleanup.ex                                          # :global.trans({__MODULE__, :committed_catalog_fixtures}, fun, ..., :infinity)
    tiny_committed_fixture.ex                           # minimal seeded catalog record
  ingestion/
    mix_task_mocks/                                     # 5 mocks: ConfigCaptureSidecarClient, CoverPipeline, Importer, SidecarClient, UnhealthySidecarClient
    provider_ingestion_worker_enrichment/               # 4 scenario mocks: cover_pipeline, importer, records, sidecar
  fixtures/provider_manifests/*.json                    # 15 manifests: 3 valid, 12 invalid (negative-path contracts)
```

## WHERE TO LOOK
| Need | Location |
|---|---|
| DB/Ash base case | `data_case.ex` |
| Conn/LiveView base case | `conn_case.ex` |
| Query-count envelope helpers | `query_counting.ex` |
| Catalog corpus seeding/teardown | `catalog/cleanup.ex`, `catalog/tiny_committed_fixture.ex` |
| Ingestion Ash builders and scenario seeds | `ingestion_fixtures.ex`, `deep_vellum_stealthy_fixture.ex` |
| Apply-phase regression harness | `apply_phase_regression_helpers.ex` |
| Mix task sidecar/cover/importer mocks | `ingestion/mix_task_mocks/` |
| Worker scenario mocks | `ingestion/provider_ingestion_worker_enrichment/` |
| Deep Vellum stealthy sidecar mock | `mock_deep_vellum_stealthy_sidecar_client.ex` |
| Manifest contract fixtures (valid + invalid) | `fixtures/provider_manifests/` |

## CONVENTIONS

**Mock contracts**
- Three runtime-configured modules use `Application.put_env(:hiraeth, :sidecar_client | :cover_pipeline | :importer, Module)` and must be reset in `on_exit` so test isolation holds.
- Worker scenario mocks read `Application.fetch_env!(:hiraeth, :provider_ingestion_worker_scenario)` and `Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)` to route per-test scenarios.

**Deterministic data**
- No Faker, no `:rand`. Every catalog/import/provenance field is a fixed literal.
- On-disk paths go under `System.tmp_dir!/System.unique_integer/[0]` so parallel runs don't collide and cleanup stays local.
- Every fixture that writes files or env keys must register `on_exit` cleanup. Leaks break `:reset_committed_catalog` and `:reset_committed_ingestion` runs.
- `Hiraeth.IngestionFixtures.catalog_writer/0` returns the single `@catalog_writer` constant actor used for all Ash creates in this harness. Don't invent per-test actors.

## ANTI-PATTERNS
- Calling `Application.put_env(:hiraeth, :sidecar_client|:cover_pipeline|:importer, ...)` without a matching `on_exit` reset.
- Reading `provider_ingestion_worker_scenario` or `provider_ingestion_worker_enrichment_test_pid` outside the four scenario mocks in `provider_ingestion_worker_enrichment/`.
- Treating `test/support/fixtures/provider_manifests/*.json` as positive-path data. They are negative-path contracts: 12 invalid + 3 valid, used to assert rejection paths.
- Mixing `priv/catalog_sources/*` and `test/support/fixtures/*` corpora. They are independent sources; never reuse a manifest or fixture file across the two roots.
- Generating fake ISBNs, authors, or publisher names with random libraries anywhere under this tree.
