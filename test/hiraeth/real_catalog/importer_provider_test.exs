defmodule Hiraeth.RealCatalogImporterProviderTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.Dataset
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @fixture_path Path.join([
                  File.cwd!(),
                  "test/fixtures/provider_seed/valid_provider.json"
                ])

  @tag timeout: 60_000
  test "seed_provider!/2 imports a single provider dataset in a transaction" do
    clear_catalog!()

    {:ok, dataset} = Dataset.load_file(@fixture_path)
    import_run = create_import_run!(dataset)

    assert {:ok, summary} =
             Hiraeth.RealCatalog.Importer.seed_provider!(dataset, import_run)

    assert summary.editions == 3
    assert summary.publishers >= 1
    assert summary.identifiers == 3
    assert summary.source_records == 3
    assert summary.cover_assignments == 3
    assert summary.import_runs >= 1

    editions = Ash.read!(Edition, authorize?: false)
    assert length(editions) == 3

    publisher =
      Ash.read!(Publisher, authorize?: false) |> Enum.find(&(&1.name == "Test Provider Press"))

    assert publisher

    identifiers = Ash.read!(Identifier, authorize?: false)
    assert length(identifiers) == 3
    assert Enum.all?(identifiers, &(&1.identifier_type == "isbn_13"))

    source_records = Ash.read!(SourceRecord, authorize?: false)
    assert length(source_records) == 3
    assert Enum.all?(source_records, &(&1.provider == "test_provider_official_site"))
    assert Enum.all?(source_records, &(&1.source_type == "publisher_dataset"))

    source_ledger = Ash.read!(SourceLedgerEntry, authorize?: false)
    assert length(source_ledger) == 3

    cover_assignments = Ash.read!(CoverAssignment, authorize?: false)
    assert length(cover_assignments) == 3

    # Verify specific records exist
    titles = Enum.map(editions, & &1.title)
    assert "Test Book One" in titles
    assert "Test Book Two" in titles
    assert "Test Book Three" in titles

    # Verify enriched metadata on book three
    book_three = Enum.find(editions, &(&1.title == "Test Book Three"))
    assert book_three.page_count == 320
    assert book_three.language_code == "eng"

    work_three = Ash.read!(Work, authorize?: false) |> Enum.find(&(&1.id == book_three.work_id))
    assert work_three.original_title == "Libro de Prueba Tres"
    assert work_three.original_language_code == "spa"
  end

  @tag timeout: 60_000
  test "seed_provider!/2 rolls back entire transaction on partial failure" do
    clear_catalog!()

    {:ok, dataset} = Dataset.load_file(@fixture_path)

    # Create a dataset where the third record has an invalid published_on date
    [r1, r2, _r3] = dataset.records

    bad_record = %{
      r1
      | source_product_id: "test-prod-bad",
        source_sku: "9780000000040",
        edition: %{r1.edition | isbn_13: "9780000000040", published_on: "not-a-date"}
    }

    bad_dataset = %{
      dataset
      | records: [r1, r2, bad_record],
        file_checksum: "bad-checksum-for-rollback-test"
    }

    import_run = create_import_run!(bad_dataset)

    assert {:error, _reason} =
             Hiraeth.RealCatalog.Importer.seed_provider!(bad_dataset, import_run)

    # Verify nothing was written to the database
    assert [] = Ash.read!(Edition, authorize?: false)
    assert [] = Ash.read!(Identifier, authorize?: false)
    assert [] = Ash.read!(SourceRecord, authorize?: false)
    assert [] = Ash.read!(SourceLedgerEntry, authorize?: false)
    assert [] = Ash.read!(CoverAssignment, authorize?: false)
    assert [] = Ash.read!(Work, authorize?: false)
    assert [] = Ash.read!(Publisher, authorize?: false)
  end

  @tag timeout: 60_000
  test "seed_provider!/2 is idempotent — re-importing the same dataset produces no duplicates" do
    clear_catalog!()

    {:ok, dataset} = Dataset.load_file(@fixture_path)
    import_run = create_import_run!(dataset)

    assert {:ok, first_summary} =
             Hiraeth.RealCatalog.Importer.seed_provider!(dataset, import_run)

    assert first_summary.editions == 3
    assert first_summary.identifiers == 3
    assert first_summary.source_records == 3

    # Second import with the same data
    second_import_run = create_import_run!(dataset)

    assert {:ok, second_summary} =
             Hiraeth.RealCatalog.Importer.seed_provider!(dataset, second_import_run)

    # Counts should remain the same — no duplicates
    assert second_summary.editions == 3
    assert second_summary.identifiers == 3
    assert second_summary.source_records == 3
    assert second_summary.cover_assignments == 3

    assert length(Ash.read!(Edition, authorize?: false)) == 3
    assert length(Ash.read!(Identifier, authorize?: false)) == 3
    assert length(Ash.read!(SourceRecord, authorize?: false)) == 3
    assert length(Ash.read!(CoverAssignment, authorize?: false)) == 3
  end

  @tag timeout: 60_000
  test "seed_provider!/2 prunes stale source records for the specific provider only" do
    clear_catalog!()

    {:ok, dataset} = Dataset.load_file(@fixture_path)
    import_run = create_import_run!(dataset)

    assert {:ok, _summary} =
             Hiraeth.RealCatalog.Importer.seed_provider!(dataset, import_run)

    assert length(Ash.read!(SourceRecord, authorize?: false)) == 3

    # Create a modified dataset with a different file_checksum and only 2 records
    [r1, r2 | _] = dataset.records
    slim_dataset = %{dataset | records: [r1, r2], file_checksum: "new-checksum-for-prune-test"}
    slim_import_run = create_import_run!(slim_dataset)

    assert {:ok, slim_summary} =
             Hiraeth.RealCatalog.Importer.seed_provider!(slim_dataset, slim_import_run)

    # The third record's source_record should be pruned
    assert slim_summary.source_records == 2
    assert length(Ash.read!(SourceRecord, authorize?: false)) == 2
    assert length(Ash.read!(Edition, authorize?: false)) == 3
  end

  @tag timeout: 300_000
  test "existing seed!/1 still works after adding seed_provider!/2" do
    clear_catalog!()

    {:ok, datasets} = Dataset.load_dir()
    expected_total = Enum.sum(Enum.map(datasets, &length(&1.records)))

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!()
    assert summary.editions == expected_total
    assert summary.publishers == length(datasets)

    assert length(Ash.read!(Edition, authorize?: false)) == expected_total
    assert length(Ash.read!(Identifier, authorize?: false)) == expected_total
    assert length(Ash.read!(SourceRecord, authorize?: false)) == expected_total
  end

  defp clear_catalog! do
    for resource <- [
          SourceLedgerEntry,
          SourceRecord,
          ImportRun,
          CoverAssignment,
          CoverAsset,
          Identifier,
          Hiraeth.Catalog.Contribution,
          Hiraeth.Catalog.SeriesMembership,
          Edition,
          Hiraeth.Catalog.Work,
          Hiraeth.Catalog.Series,
          Hiraeth.Catalog.Imprint,
          Hiraeth.Catalog.Contributor,
          Publisher
        ] do
      Hiraeth.Repo.delete_all(resource)
    end
  end

  defp create_import_run!(dataset) do
    ImportRun
    |> Ash.Changeset.for_create(:create, %{
      provider: dataset.provider,
      status: "applied",
      row_limit: length(dataset.records || [])
    })
    |> Ash.create!(authorize?: false)
  end
end
