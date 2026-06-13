defmodule Hiraeth.AshPostgresMigrationTest do
  use Hiraeth.DataCase, async: true

  @public_catalog_indexes ~w(
    editions_public_catalog_work_id_index
    editions_public_catalog_publisher_id_index
    editions_public_catalog_imprint_id_index
    identifiers_public_catalog_edition_id_index
    identifiers_public_catalog_value_index
    cover_assignments_public_catalog_edition_id_index
    cover_assignments_public_catalog_cover_asset_id_index
    contributions_public_catalog_work_id_index
    contributions_public_catalog_edition_id_index
    contributions_public_catalog_contributor_id_index
    series_memberships_public_catalog_work_id_index
    series_memberships_public_catalog_series_id_index
    source_records_public_catalog_source_uri_index
    source_records_public_catalog_provider_type_index
    source_records_public_catalog_isbn_expr_index
    works_public_catalog_title_trgm_index
    works_public_catalog_subtitle_trgm_index
    editions_public_catalog_title_trgm_index
    editions_public_catalog_subtitle_trgm_index
    publishers_public_catalog_name_trgm_index
    contributors_public_catalog_display_name_trgm_index
    series_public_catalog_title_trgm_index
    identifiers_public_catalog_normalized_value_trgm_index
  )

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

  test "public catalog read paths have explicit postgres indexes" do
    assert {:ok, %{rows: rows}} =
             Hiraeth.Repo.query(
               """
               select indexname
               from pg_indexes
               where schemaname = 'public'
               """,
               []
             )

    index_names = rows |> List.flatten() |> MapSet.new()

    for index_name <- @public_catalog_indexes do
      assert index_name in index_names
    end
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
