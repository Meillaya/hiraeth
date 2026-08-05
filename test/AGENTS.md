# TEST KNOWLEDGE BASE

## OVERVIEW
Fixture-driven, contract-heavy ExUnit and pytest-adjacent validation for Hiraeth boundaries. Inherits repo-wide rules from `../AGENTS.md`; do not duplicate them here.

## WHERE TO LOOK
| Test need | Location |
|---|---|
| DB/domain tests | `test/support/data_case.ex` + `test/hiraeth/**` |
| Controller/LiveView tests | `test/support/conn_case.ex` + `test/hiraeth_web/**` |
| Contract drift checks | `test/hiraeth/**/*_contract_test.exs` |
| Static fixtures | `test/fixtures/**`, `test/support/fixtures/**` |
| Fixture builders/reset helpers | `test/support/**/*fixture*.ex`, `test/support/catalog/cleanup.ex` |
| Sidecar pytest | `sidecar/tests/**` (see `sidecar/AGENTS.md`) |

## TAG CONTRACT
| Tag | Meaning |
|---|---|
| `:slow` | excluded from `mix test.fast` |
| `:full_catalog` | committed corpus / coverage-heavy work |
| `:integration` | external process or broad integration boundary |
| `:performance` | latency/query-count envelope |
| `:browser` | browser QA or browser contract lane |
| `:public_catalog_full` | expensive public catalog UI/data sweep |
| `:reset_committed_catalog` | DataCase resets committed catalog fixtures |
| `:reset_committed_ingestion` | DataCase resets ingestion control-plane fixtures |
| `:ci_devenv_contract` | descriptive: marks the dual devenv/legacy-Compose CI lane contract (never excluded) |

## CONVENTIONS
- Choose base case by boundary: `DataCase` for DB/Ash; `ConnCase` for conn/LiveView; plain `ExUnit.Case` for file/command/docs contracts.
- Prefer `async: false` when touching shared DB state, committed corpus, browser flows, or global filesystem artifacts.
- Contract tests assert static promises: docs, Mix aliases, devenv/CI contracts, route matrices, script command order, OpenAPI snapshots.
- Fixture data is deterministic, checked in, and provenance-bearing. No random/Faker metadata in catalog/import/provenance paths.
- LiveView tests import `Phoenix.LiveViewTest` and assert with stable selectors via `has_element?/2`, `element/2`, `form`, `render_change`, `render_submit`.
- Use helper reset tags instead of ad hoc truncation/setup in individual tests.
- Use explicit `@tag timeout: ...` for genuinely long tests rather than sleeps.
- Tag exclusions live in the `mix test.fast` alias (not `test_helper.exs`) and are locked by `test/hiraeth/mix_alias_contract_test.exs`; the sandbox runs in manual mode, so DataCase/ConnCase own their connections.

## ANTI-PATTERNS
- Raw HTML string assertions for LiveView structure when a stable selector exists.
- `Process.sleep/1` synchronization; use monitors, messages, or state synchronization helpers.
- New expensive tests without one of the existing cost tags.
- Updating snapshots/coverage reports without verifying the generator and policy implications.
- Live network dependency in deterministic fixture tests.
