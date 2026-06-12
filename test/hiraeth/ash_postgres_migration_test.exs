defmodule Hiraeth.AshPostgresMigrationTest do
  use Hiraeth.DataCase, async: true

  @expected_tables ~w(
    users
    tokens
    publishers
    imprints
    works
    editions
    contributors
    contributions
    identifiers
    series
    series_memberships
    source_records
    curation_overrides
    source_ledger_entries
    cover_assets
    cover_assignments
    import_runs
    import_mappings
    staged_import_rows
    review_items
    audit_events
  )

  test "AshPostgres migrations create expected domain tables without a flat books table" do
    assert {:ok, %{rows: rows}} =
             Hiraeth.Repo.query(
               """
               select table_name
               from information_schema.tables
               where table_schema = 'public' and table_type = 'BASE TABLE'
               """,
               []
             )

    table_names = rows |> List.flatten() |> MapSet.new()

    for table <- @expected_tables do
      assert table in table_names
    end

    refute "books" in table_names
  end

  test "work and edition tables are distinct with edition foreign keys" do
    assert {:ok, %{rows: rows}} =
             Hiraeth.Repo.query(
               """
               select table_name, column_name
               from information_schema.columns
               where table_schema = 'public'
                 and table_name in ('works', 'editions', 'identifiers', 'cover_assignments')
               """,
               []
             )

    columns = MapSet.new(rows)

    assert ["works", "id"] in columns
    assert ["editions", "id"] in columns
    assert ["editions", "work_id"] in columns
    assert ["identifiers", "edition_id"] in columns
    assert ["cover_assignments", "edition_id"] in columns
  end
end
