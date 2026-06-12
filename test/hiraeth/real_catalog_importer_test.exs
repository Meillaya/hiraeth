defmodule Hiraeth.RealCatalogImporterTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Accounts.User
  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.Dataset
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  test "real catalog importer seeds approved publisher records with provenance and covers idempotently" do
    clear_catalog!()

    assert {:ok, first_summary} = Hiraeth.RealCatalog.Importer.seed!()
    assert first_summary.editions == 150
    assert first_summary.publishers == 3

    assert Enum.any?(Ash.read!(Publisher, authorize?: false), &(&1.name == "Deep Vellum"))
    assert Enum.any?(Ash.read!(Publisher, authorize?: false), &(&1.name == "Dalkey Archive"))
    assert Enum.any?(Ash.read!(Publisher, authorize?: false), &(&1.name == "Archipelago Books"))

    editions = Ash.read!(Edition, authorize?: false)
    identifiers = Ash.read!(Identifier, authorize?: false)
    source_records = Ash.read!(SourceRecord, authorize?: false)
    source_ledger = Ash.read!(SourceLedgerEntry, authorize?: false)
    cover_assets = Ash.read!(CoverAsset, authorize?: false)
    cover_assignments = Ash.read!(CoverAssignment, authorize?: false)
    import_runs = Ash.read!(ImportRun, authorize?: false)

    assert length(editions) == 150
    assert length(identifiers) == 150
    assert length(source_records) == 150
    assert length(source_ledger) >= 150
    assert length(cover_assets) >= 3
    assert length(cover_assignments) == 150
    assert length(import_runs) == 3

    refute Enum.any?(
             Ash.read!(User, authorize?: false),
             &(to_string(&1.email) == "real-catalog-admin@example.test")
           )

    assert Enum.all?(source_records, &(&1.source_type == "publisher_dataset"))

    assert Enum.all?(
             source_records,
             &String.contains?(&1.license_note, "approved public prose metadata")
           )

    assert Enum.all?(source_records, &is_binary(&1.import_run_id))
    assert Enum.all?(cover_assets, &(&1.cache_policy == "link_only"))
    assert Enum.all?(cover_assets, &is_nil(&1.cached_file_path))

    assert {:ok, datasets} = Dataset.load_dir()
    dataset_file_checksums = datasets |> Enum.map(& &1.file_checksum) |> Enum.sort()

    assert source_records
           |> Enum.map(& &1.file_checksum)
           |> Enum.uniq()
           |> Enum.sort() == dataset_file_checksums

    assert Enum.any?(editions, &(&1.title == "Immigrant" and &1.format == "paperback"))
    assert Enum.any?(editions, &(&1.title == "The Tunnel" and &1.format == "paperback"))
    assert Enum.any?(editions, &(&1.title == "Bob and Hilbert" and &1.format == "hardcover"))

    assert {:ok, second_summary} = Hiraeth.RealCatalog.Importer.seed!()
    assert second_summary.editions == 150

    assert length(Ash.read!(Edition, authorize?: false)) == 150
    assert length(Ash.read!(Identifier, authorize?: false)) == 150
    assert length(Ash.read!(SourceRecord, authorize?: false)) == 150
    assert length(Ash.read!(CoverAssignment, authorize?: false)) == 150
    assert length(Ash.read!(ImportRun, authorize?: false)) == 3
  end

  test "real catalog importer accepts validated no-cover records without creating cover assignments" do
    clear_catalog!()
    tmp = no_cover_dataset_dir!(:delete_cover)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert summary.editions == 50
    assert summary.cover_assignments == 49

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        get_in(source_record.raw_payload || %{}, ["edition", "isbn_13"]) == "9781962770651"
      end)

    assert source_record

    assert source_record.raw_payload["no_cover_reason"] ==
             "Official public source exposes no cover image."
  end

  test "real catalog importer treats empty cover maps with no-cover reasons as no-cover records" do
    clear_catalog!()
    tmp = no_cover_dataset_dir!(:empty_cover)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert summary.editions == 50
    assert summary.cover_assignments == 49

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        get_in(source_record.raw_payload || %{}, ["edition", "isbn_13"]) == "9781962770651"
      end)

    assert source_record
    refute Map.has_key?(source_record.raw_payload, "cover")

    assert source_record.raw_payload["no_cover_reason"] ==
             "Official public source exposes no cover image."
  end

  test "real catalog importer creates checksum-versioned source records and updates missing work prose" do
    clear_catalog!()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-reimport-prose-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))

    record = Enum.find(dataset.records, &(not Map.has_key?(&1, :description)))
    remaining_records = List.delete(dataset.records, record)

    write_archipelago_payload!(tmp, dataset, record, remaining_records)

    assert {:ok, first_summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert first_summary.source_records == 50

    work = Work |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == record.work.title))
    assert is_nil(work.description)

    prose_record =
      record
      |> Map.put(:description, "A later checksum-versioned official synopsis.")
      |> Map.put(:storefront_url, record.source_uri)
      |> Map.put(:editorial_praise, [
        %{
          quote: "Later sourced praise.",
          source: "Publisher official page",
          source_uri: record.source_uri
        }
      ])
      |> Map.update!(:displayed_fields, fn fields ->
        Enum.uniq(fields ++ ["description", "editorial_praise", "storefront_url"])
      end)

    write_archipelago_payload!(tmp, dataset, prose_record, remaining_records)

    assert {:ok, second_summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert second_summary.editions == 50
    assert second_summary.source_records == 100

    updated_work =
      Work
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.title == record.work.title))

    assert updated_work.description == "A later checksum-versioned official synopsis."
    assert updated_work.storefront_url == record.source_uri
    assert [%{"quote" => "Later sourced praise."}] = updated_work.editorial_praise
  end

  test "real catalog importer persists sourced prose and storefront CTA for public display" do
    clear_catalog!()
    tmp = prose_dataset_dir!()
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, _summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)

    work = Work |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == "Bob and Hilbert"))
    assert work.description == "A sourced synopsis carried from the official publisher page."

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        get_in(source_record.raw_payload || %{}, ["work", "title"]) == "Bob and Hilbert"
      end)

    assert source_record.raw_payload["description"] ==
             "A sourced synopsis carried from the official publisher page."

    assert source_record.raw_payload["storefront_url"] ==
             "https://archipelagobooks.org/book/bob-and-hilbert/"

    assert [praise] = source_record.raw_payload["editorial_praise"]
    assert praise["quote"] == "A precise, source-attributed editorial praise excerpt."
    assert praise["source_uri"] == "https://archipelagobooks.org/book/bob-and-hilbert/"
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
          Edition,
          Hiraeth.Catalog.Work,
          Hiraeth.Catalog.Imprint,
          Publisher,
          User
        ] do
      Hiraeth.Repo.delete_all(resource)
    end
  end

  defp write_archipelago_payload!(dir, dataset, first_record, remaining_records) do
    payload = %{
      provider: dataset.provider,
      retrieved_at: dataset.retrieved_at,
      license_note: dataset.license_note,
      records: [first_record | remaining_records]
    }

    File.write!(Path.join(dir, "archipelago_books.json"), Jason.encode!(payload, pretty: true))
  end

  defp no_cover_dataset_dir!(shape) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-no-cover-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    no_cover_record =
      record
      |> no_cover_shape(shape)
      |> Map.put(:no_cover_reason, "Official public source exposes no cover image.")
      |> Map.update!(:displayed_fields, &List.delete(&1, "cover"))

    payload = %{
      provider: dataset.provider,
      retrieved_at: dataset.retrieved_at,
      license_note: dataset.license_note,
      records: [no_cover_record | remaining_records]
    }

    File.write!(Path.join(tmp, "archipelago_books.json"), Jason.encode!(payload, pretty: true))
    tmp
  end

  defp no_cover_shape(record, :delete_cover), do: Map.delete(record, :cover)
  defp no_cover_shape(record, :empty_cover), do: Map.put(record, :cover, %{})

  defp prose_dataset_dir! do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-prose-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    prose_record =
      record
      |> Map.put(:description, "A sourced synopsis carried from the official publisher page.")
      |> Map.put(:storefront_url, record.source_uri)
      |> Map.put(:editorial_praise, [
        %{
          quote: "A precise, source-attributed editorial praise excerpt.",
          source: "Publisher official page",
          source_uri: record.source_uri
        }
      ])
      |> Map.update!(:displayed_fields, fn fields ->
        Enum.uniq(fields ++ ["description", "editorial_praise", "storefront_url"])
      end)

    payload = %{
      provider: dataset.provider,
      retrieved_at: dataset.retrieved_at,
      license_note: dataset.license_note,
      records: [prose_record | remaining_records]
    }

    File.write!(Path.join(tmp, "archipelago_books.json"), Jason.encode!(payload, pretty: true))
    tmp
  end
end
