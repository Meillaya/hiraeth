lanes = Code.eval_file(Path.expand("../priv/test_lanes.exs", __DIR__)) |> elem(0)
ExUnit.start(exclude: lanes.nightly_tags)
Ecto.Adapters.SQL.Sandbox.mode(Hiraeth.Repo, :manual)

# Delete any committed corpus persisted from a previous run BEFORE any test
# starts. Clearing tests (apply_phase, provenance_audit, importer, e2e, ...)
# then run against an empty committed state: their sandbox-scoped deletes are
# no-ops that never contend on corpus rows held by long sandbox transactions
# (which previously caused 57014 query-canceled timeouts and 40P01 deadlocks),
# and the LiveView/public files reseed the committed corpus once via
# ensure_committed_catalog_fixtures!(). This runs before any sandbox owner,
# so it is race-free by construction.
:ok =
  Ecto.Adapters.SQL.Sandbox.unboxed_run(Hiraeth.Repo, fn ->
    for table <- ~w(
          source_ledger_entries
          curation_overrides
          source_records
          import_runs
          cover_assignments
          cover_assets
          identifiers
          contributions
          series_memberships
          editions
          works
          series
          imprints
          contributors
          publishers
          oban_jobs
        ) do
      Hiraeth.Repo.query!("DELETE FROM #{table}", [], timeout: :infinity)
    end

    :ok
  end)
