defmodule Hiraeth.RealCatalogImporterProviderTest do
  use Hiraeth.DataCase, async: false

  @moduletag :reset_committed_catalog

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Covers.CoverAssignment
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
  test "seed_provider!/2 accepts an extended transaction timeout for large provider imports" do
    clear_catalog!()

    {:ok, dataset} = Dataset.load_file(@fixture_path)
    import_run = create_import_run!(dataset)

    assert {:ok, summary} =
             Hiraeth.RealCatalog.Importer.seed_provider!(dataset, import_run,
               transaction_timeout: :infinity
             )

    assert summary.source_records == 3
    assert length(Ash.read!(SourceRecord, authorize?: false)) == 3
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

  @tag timeout: 60_000
  test "seed_provider!/2 groups Astra sibling format pages into one work with multiple editions" do
    clear_catalog!()

    dataset = astra_house_sibling_dataset()
    import_run = create_import_run!(dataset)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed_provider!(dataset, import_run)
    assert summary.editions == 2

    works = Ash.read!(Work, authorize?: false)
    assert length(works) == 1
    assert hd(works).title == "Early Sobrieties"

    editions = Ash.read!(Edition, authorize?: false)
    assert length(editions) == 2
    assert Enum.map(editions, & &1.work_id) |> Enum.uniq() == [hd(works).id]
    assert Enum.sort(Enum.map(editions, & &1.format)) == ["ebook", "paperback"]
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

  defp astra_house_sibling_dataset do
    records = [
      astra_house_record(
        "https://astrapublishinghouse.com/product/early-sobrieties-9781662602245/",
        "9781662602245",
        "paperback"
      ),
      astra_house_record(
        "https://astrapublishinghouse.com/product/early-sobrieties-9781662602252/",
        "9781662602252",
        "ebook"
      )
    ]

    Dataset.normalize(%{
      provider: "astra_house_official_store",
      file: "astra-house-sibling-test.json",
      file_path: "test/fixtures/astra-house-sibling-test.json",
      file_checksum: "astra-house-sibling-checksum",
      license_note: "fixture",
      provider_permissions: %{
        provider: "astra_house_official_store",
        source_urls: ["https://astrapublishinghouse.com/imprints/astra-house/"],
        source_hosts: ["astrapublishinghouse.com"],
        cover_hosts: ["images.penguinrandomhouse.com"],
        permission_basis: "test permission",
        cover_cache_policy: "cache_allowed",
        excluded_content: ["raw_html"],
        takedown_contact: "https://astrapublishinghouse.com/contact/",
        not_legal_advice: true
      },
      records: records
    })
  end

  defp astra_house_record(source_uri, isbn, format) do
    fields =
      ~w(title contributors publisher format published_on isbn_13 cover description storefront_url)

    %{
      source_uri: source_uri,
      source_product_id: isbn,
      source_sku: isbn,
      publisher: "Astra House",
      imprint: "Astra House",
      work: %{
        title: "Early Sobrieties",
        subtitle: nil,
        original_title: nil,
        original_language_code: nil,
        publication_state: "published",
        subjects: ["fiction"]
      },
      edition: %{
        title: "Early Sobrieties",
        subtitle: nil,
        format: format,
        published_on: "2024-05-07",
        isbn_13: isbn
      },
      contributors: [%{name: "Michael Deagler", role: "author"}],
      displayed_fields: fields,
      curation: %{status: "approved", notes: "fixture"},
      storefront_url: source_uri,
      field_sources:
        Map.new(fields, fn field ->
          {field,
           %{
             provider: "astra_house_official_store",
             source_uri: source_uri,
             source_type: "publisher_dataset",
             rights_basis: "test"
           }}
        end),
      cover: %{
        source_url: "https://images.penguinrandomhouse.com/cover/700jpg/#{isbn}",
        provider: "astra_house_official_store",
        rights_basis: "local_cache_permitted",
        attribution_text: "Cover via Astra House official source",
        attribution_url: source_uri,
        cache_policy: "cache_allowed"
      },
      description: "An Astra House novel fixture."
    }
  end

  defp clear_catalog!, do: Hiraeth.CatalogCleanup.clear_catalog!()

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
