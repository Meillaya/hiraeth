defmodule Hiraeth.RealCatalogImporterTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Covers.{CoverAsset, CoverAssignment}
  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.RealCatalog.{Dataset, Slug}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  @tag timeout: 180_000
  test "real catalog importer seeds approved publisher records with provenance and covers idempotently" do
    clear_catalog!()

    {:ok, datasets} = Dataset.load_dir()
    first_cover = datasets |> hd() |> Map.fetch!(:records) |> hd() |> Map.fetch!(:cover)

    {:ok, archipelago_dataset} =
      Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))

    legacy_asset =
      CoverAsset
      |> Ash.Changeset.for_create(:create, %{
        source_url: first_cover.source_url,
        provider: first_cover.provider,
        rights_basis: "provider_link_allowed",
        attribution_text: "Legacy attribution",
        attribution_url: nil,
        cache_policy: "link_only",
        takedown_state: "visible"
      })
      |> Ash.create!(authorize?: false)

    expected_total = Enum.sum(Enum.map(datasets, &length(&1.records)))
    expected_cover_assignments = count_cover_records(datasets)
    expected_transit_count = provider_record_count(datasets, "transit_books_official_site")

    assert {:ok, first_summary} = Hiraeth.RealCatalog.Importer.seed!()
    assert first_summary.editions == expected_total
    assert first_summary.publishers == length(datasets)

    publisher_names = Ash.read!(Publisher, authorize?: false) |> Enum.map(& &1.name)

    for name <- [
          "Deep Vellum",
          "Dalkey Archive",
          "Archipelago Books",
          "New Directions",
          "Transit Books",
          "Historical Materialism",
          "Semiotext(e)",
          "Phoneme Media",
          "A Strange Object",
          "La Reunion",
          "Fum d'Estampa",
          "Fitzcarraldo Editions",
          "NYRB",
          "Tilted Axis Press",
          "McNally Editions",
          "Seven Stories Press",
          "Unnamed Press",
          "Pushkin Press"
        ] do
      assert name in publisher_names
    end

    editions = Ash.read!(Edition, authorize?: false)
    identifiers = Ash.read!(Identifier, authorize?: false)
    source_records = Ash.read!(SourceRecord, authorize?: false)
    source_ledger = Ash.read!(SourceLedgerEntry, authorize?: false)
    cover_assets = Ash.read!(CoverAsset, authorize?: false)
    cover_assignments = Ash.read!(CoverAssignment, authorize?: false)
    import_runs = Ash.read!(ImportRun, authorize?: false)

    assert length(editions) == expected_total
    assert length(identifiers) == expected_total
    assert length(source_records) == expected_total
    assert length(source_ledger) >= expected_total
    assert length(cover_assets) >= 5
    assert length(cover_assignments) == expected_cover_assignments
    assert length(import_runs) == length(datasets)

    dataset_providers = MapSet.new(Enum.map(datasets, & &1.provider))

    assert Enum.all?(source_records, fn source_record ->
             source_record.source_type in ["publisher_dataset", "publisher_official_page"] and
               MapSet.member?(dataset_providers, source_record.provider)
           end)

    assert Enum.all?(source_records, fn %{license_note: license_note} ->
             String.contains?(license_note, "Operator-authorized public catalog refresh")
           end)

    assert Enum.all?(source_records, &is_binary(&1.import_run_id))
    assert Enum.all?(source_records, &is_binary(&1.source_identity))
    assert Enum.all?(source_records, &is_binary(&1.edition_id))
    assert Enum.all?(cover_assets, &(&1.cache_policy == "cache_allowed"))
    assert Enum.all?(cover_assets, &is_nil(&1.cached_file_path))

    synced_asset = Enum.find(cover_assets, &(&1.id == legacy_asset.id))
    assert synced_asset.provider == first_cover.provider
    assert synced_asset.rights_basis == "local_cache_permitted"
    assert synced_asset.attribution_text == first_cover.attribution_text
    assert synced_asset.attribution_url == first_cover.attribution_url
    assert synced_asset.cache_policy == "cache_allowed"

    assert {:ok, datasets} = Dataset.load_dir()
    dataset_file_checksums = datasets |> Enum.map(& &1.file_checksum) |> Enum.sort()

    assert source_records
           |> Enum.map(& &1.file_checksum)
           |> Enum.uniq()
           |> Enum.sort() == dataset_file_checksums

    assert Enum.any?(editions, &(&1.title == "Immigrant" and &1.format == "paperback"))
    assert Enum.any?(editions, &(&1.title == "The Tunnel" and &1.format == "paperback"))
    assert Enum.any?(editions, &(&1.title == "Bob and Hilbert" and &1.format == "hardcover"))
    assert Enum.any?(editions, &(&1.title == "Cold Mountain Zen" and &1.format == "paperback"))

    assert Enum.any?(
             editions,
             &(&1.title == "May We Feed the King" and &1.format == "paperback")
           )

    transit_source_records =
      Enum.filter(source_records, &(&1.provider == "transit_books_official_site"))

    assert length(transit_source_records) == expected_transit_count

    assert Enum.all?(transit_source_records, fn source_record ->
             payload = source_record.raw_payload || %{}

             String.starts_with?(source_record.source_uri, "https://www.transitbooks.org/books/") and
               payload["provider_permissions"]["source_urls"] == [
                 "https://www.transitbooks.org/sitemap.xml",
                 "https://www.transitbooks.org/books"
               ] and
               payload["provider_permissions"]["permission_basis"] =~
                 "Operator-authorized public catalog refresh" and
               payload["provider_permissions"]["cover_hosts"] == [
                 "images.squarespace-cdn.com",
                 "static1.squarespace.com",
                 "covers.openlibrary.org"
               ] and
               payload["provider_permissions"]["cover_cache_policy"] == "cache_allowed" and
               Map.has_key?(payload, "cover") and
               not Map.has_key?(payload, "no_cover_reason")
           end)

    bob_cover_urls =
      archipelago_dataset.records
      |> Enum.filter(&(&1.source_sku in ["9781962770651", "9781962770668"]))
      |> Enum.map(&get_in(&1, [:cover, :source_url]))
      |> Enum.uniq()

    assert length(bob_cover_urls) == 1
    assert [bob_cover_url] = bob_cover_urls
    assert String.starts_with?(bob_cover_url, "https://archipelagobooks.org/wp-content/uploads/")

    assert {:ok, second_summary} = Hiraeth.RealCatalog.Importer.seed!()
    assert second_summary.editions == expected_total

    assert length(Ash.read!(Edition, authorize?: false)) == expected_total
    assert length(Ash.read!(Identifier, authorize?: false)) == expected_total
    assert length(Ash.read!(SourceRecord, authorize?: false)) == expected_total
    assert length(Ash.read!(CoverAssignment, authorize?: false)) == expected_cover_assignments
    assert length(Ash.read!(ImportRun, authorize?: false)) == length(datasets)
  end

  test "real catalog importer accepts validated no-cover records without creating cover assignments" do
    clear_catalog!()
    tmp = no_cover_dataset_dir!(:delete_cover)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert summary.editions == archipelago_record_count()
    assert summary.cover_assignments == archipelago_cover_count() - 1

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        source_record.raw_payload["no_cover_reason"] ==
          "Official public source exposes no cover image."
      end)

    assert source_record

    assert source_record.raw_payload["no_cover_reason"] ==
             "Official public source exposes no cover image."
  end

  test "real catalog importer adopts existing deterministic cover cache files when reseeding" do
    clear_catalog!()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-cache-adoption-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    cover = %{
      record.cover
      | source_url:
          "https://archipelagobooks.org/wp-content/uploads/hiraeth-seed-cache-adoption-test.jpg",
        rights_basis: "local_cache_permitted",
        cache_policy: "cache_allowed"
    }

    cache_probe = %CoverAsset{source_url: cover.source_url}
    cached_path = Hiraeth.Covers.cache_path(cache_probe)
    thumbnail_path = Hiraeth.Covers.thumbnail_path(cache_probe)

    on_exit(fn ->
      File.rm(cached_path)
      File.rm(thumbnail_path)
      File.rm_rf!(tmp)
    end)

    File.mkdir_p!(Path.dirname(cached_path))
    File.write!(cached_path, "cached original bytes")
    File.write!(thumbnail_path, "cached thumbnail bytes")

    cached_record = %{record | cover: cover}
    write_archipelago_payload!(tmp, dataset, cached_record, remaining_records)

    assert {:ok, _summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)

    cached_asset =
      CoverAsset
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.source_url == cover.source_url))

    assert cached_asset.cached_file_path == cached_path
    assert cached_asset.thumbnail_file_path == thumbnail_path
    assert File.read!(cached_asset.cached_file_path) == "cached original bytes"
    assert File.read!(cached_asset.thumbnail_file_path) == "cached thumbnail bytes"

    cached_asset
    |> Ash.Changeset.for_update(:update, %{
      cached_file_path: nil,
      thumbnail_file_path: nil,
      cached_at: nil
    })
    |> Ash.update!(authorize?: false)

    assert {:ok, _summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)

    repaired_asset =
      CoverAsset
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.source_url == cover.source_url))

    assert repaired_asset.cached_file_path == cached_path
    assert repaired_asset.thumbnail_file_path == thumbnail_path
  end

  test "real catalog importer treats empty cover maps with no-cover reasons as no-cover records" do
    clear_catalog!()
    tmp = no_cover_dataset_dir!(:empty_cover)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert summary.editions == archipelago_record_count()
    assert summary.cover_assignments == archipelago_cover_count() - 1

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        source_record.raw_payload["no_cover_reason"] ==
          "Official public source exposes no cover image."
      end)

    assert source_record
    refute Map.has_key?(source_record.raw_payload, "cover")

    assert source_record.raw_payload["no_cover_reason"] ==
             "Official public source exposes no cover image."
  end

  test "real catalog importer accepts source-only no-ISBN editions with stable provenance" do
    clear_catalog!()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-no-isbn-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    no_isbn_record =
      record
      |> update_in([:edition], &Map.delete(&1, :isbn_13))
      |> Map.put(:source_sku, "source-only-#{record.source_product_id}")
      |> Map.put(:missing_fields, %{
        "isbn_13" => "Approved source record has no ISBN for this edition."
      })
      |> Map.update!(:displayed_fields, &List.delete(&1, "isbn_13"))
      |> Map.update!(:field_sources, &Map.delete(&1, "isbn_13"))

    write_archipelago_payload!(tmp, dataset, no_isbn_record, remaining_records)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert summary.editions == archipelago_record_count()
    assert summary.identifiers == archipelago_record_count()
    assert summary.source_records == archipelago_record_count()

    edition =
      Edition
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.title == record.edition.title))

    assert edition

    assert Enum.any?(
             Ash.read!(Identifier, authorize?: false),
             &(&1.edition_id == edition.id and &1.identifier_type == "source_record" and
                 &1.value == "source:#{dataset.provider}:#{record.source_product_id}")
           )

    assert String.ends_with?(
             edition.slug,
             "source-#{Slug.slugify(record.source_product_id)}"
           )

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        source_record.raw_payload["source_product_id"] == record.source_product_id
      end)

    assert source_record
    assert String.ends_with?(source_record.source_uri, "#source-#{record.source_product_id}")

    assert source_record.source_identity ==
             "source:#{dataset.provider}:#{record.source_product_id}"

    assert source_record.edition_id == edition.id

    assert source_record.raw_payload["source_identity"] ==
             "source:#{dataset.provider}:#{record.source_product_id}"

    assert source_record.raw_payload["identifier"]["source_identity"] ==
             "source:#{dataset.provider}:#{record.source_product_id}"

    refute Map.has_key?(source_record.raw_payload["identifier"], "isbn_13")

    refute Map.has_key?(source_record.raw_payload["edition"], "isbn_13")

    assert source_record.raw_payload["missing_fields"]["isbn_13"] ==
             "Approved source record has no ISBN for this edition."
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

    record =
      dataset.records
      |> unique_title_record!()
      |> Map.delete(:description)
      |> Map.update!(:displayed_fields, &List.delete(&1, "description"))
      |> Map.update!(:field_sources, &Map.delete(&1, "description"))

    remaining_records =
      Enum.reject(dataset.records, &(&1.source_product_id == record.source_product_id))

    write_archipelago_payload!(tmp, dataset, record, remaining_records)

    assert {:ok, first_summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert first_summary.source_records == archipelago_record_count()

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
      |> put_field_sources(dataset, ["description", "editorial_praise", "storefront_url"])

    write_archipelago_payload!(tmp, dataset, prose_record, remaining_records)

    assert {:ok, second_summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert second_summary.editions == archipelago_record_count()
    assert second_summary.source_records == archipelago_record_count() * 2

    updated_work =
      Work
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.title == record.work.title))

    assert updated_work.description == "A later checksum-versioned official synopsis."
    assert updated_work.storefront_url == record.source_uri
    assert [%{"quote" => "Later sourced praise."}] = updated_work.editorial_praise

    updated_work
    |> Ash.Changeset.for_update(:update, %{description: "Curated nonblank synopsis."})
    |> Ash.update!(authorize?: false)

    overwrite_attempt =
      Map.put(prose_record, :description, "A newer source should not overwrite curation.")

    write_archipelago_payload!(tmp, dataset, overwrite_attempt, remaining_records)

    assert {:ok, third_summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert third_summary.source_records == archipelago_record_count() * 3

    preserved_work =
      Work |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == record.work.title))

    assert preserved_work.description == "Curated nonblank synopsis."
  end

  test "real catalog importer ingests enriched metadata and preserves field provenance payload" do
    clear_catalog!()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-enriched-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    enriched_record =
      record
      |> put_in([:work, :original_title], "Bob og Hilbert")
      |> put_in([:work, :original_language_code], "fao")
      |> put_in([:work, :subjects], ["picture books", "friendship"])
      |> put_in([:edition, :language_code], "eng")
      |> put_in([:edition, :page_count], 48)
      |> put_in([:edition, :dimensions], %{height_mm: 250, width_mm: 210, depth_mm: 8})
      |> Map.update!(:displayed_fields, fn fields ->
        Enum.uniq(
          fields ++
            [
              "original_title",
              "original_language_code",
              "subjects",
              "language_code",
              "page_count",
              "dimensions"
            ]
        )
      end)
      |> Map.update!(:field_sources, fn sources ->
        rich_source = %{
          provider: dataset.provider,
          source_uri: record.source_uri,
          source_type: "publisher_dataset",
          rights_basis: dataset.license_note
        }

        sources
        |> Map.put("original_title", rich_source)
        |> Map.put("original_language_code", rich_source)
        |> Map.put("subjects", rich_source)
        |> Map.put("language_code", rich_source)
        |> Map.put("page_count", rich_source)
        |> Map.put("dimensions", rich_source)
      end)

    write_archipelago_payload!(tmp, dataset, enriched_record, remaining_records)

    assert {:ok, summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    assert summary.editions == archipelago_record_count()

    work = Work |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == record.work.title))
    edition = Edition |> Ash.read!(authorize?: false) |> Enum.find(&(&1.work_id == work.id))

    assert work.original_title == "Bob og Hilbert"
    assert work.original_language_code == "fao"
    assert work.subjects == ["picture books", "friendship"]
    assert edition.language_code == "eng"
    assert edition.page_count == 48
    assert edition.height_mm == 250
    assert edition.width_mm == 210
    assert edition.depth_mm == 8

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        get_in(source_record.raw_payload || %{}, ["edition", "isbn_13"]) ==
          record.edition.isbn_13
      end)

    assert source_record.raw_payload["field_sources"]["dimensions"]["provider"] ==
             dataset.provider

    assert source_record.raw_payload["provider_permissions"]["provider"] == dataset.provider
    assert source_record.raw_payload["work"]["subjects"] == ["picture books", "friendship"]
    assert source_record.raw_payload["edition"]["page_count"] == 48
    assert source_record.raw_payload["edition"]["dimensions"]["height_mm"] == 250
  end

  test "real catalog importer rejects rich metadata without field provenance" do
    clear_catalog!()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hiraeth-unsourced-rich-real-catalog-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    File.cp!(Path.join(Dataset.default_dir(), "README.md"), Path.join(tmp, "README.md"))
    File.cp!(Path.join(Dataset.default_dir(), "schema.json"), Path.join(tmp, "schema.json"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    [record | remaining_records] = dataset.records

    unsourced_record =
      record
      |> put_in([:work, :original_language_code], "fao")
      |> Map.update!(:displayed_fields, &List.delete(&1, "original_language_code"))
      |> Map.update!(:field_sources, &Map.delete(&1, "original_language_code"))

    write_archipelago_payload!(tmp, dataset, unsourced_record, remaining_records)

    assert {:error, findings} = Hiraeth.RealCatalog.Importer.seed!(tmp)
    reasons = Enum.map(findings, & &1.reason)

    assert "rich metadata field requires field_sources provenance" in reasons
    assert [] = Ash.read!(Work, authorize?: false)
  end

  test "real catalog importer persists sourced prose and storefront CTA for public display" do
    clear_catalog!()
    tmp = prose_dataset_dir!()
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, _summary} = Hiraeth.RealCatalog.Importer.seed!(tmp)

    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    record = unique_title_record!(dataset.records)

    work = Work |> Ash.read!(authorize?: false) |> Enum.find(&(&1.title == record.work.title))
    assert work.description == "A sourced synopsis carried from the official publisher page."

    source_record =
      SourceRecord
      |> Ash.read!(authorize?: false)
      |> Enum.find(fn source_record ->
        get_in(source_record.raw_payload || %{}, ["work", "title"]) == record.work.title
      end)

    assert source_record.raw_payload["description"] ==
             "A sourced synopsis carried from the official publisher page."

    assert source_record.raw_payload["storefront_url"] == record.source_uri

    assert [praise] = source_record.raw_payload["editorial_praise"]
    assert praise["quote"] == "A precise, source-attributed editorial praise excerpt."
    assert praise["source_uri"] == record.source_uri
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
          Publisher
        ] do
      Hiraeth.Repo.delete_all(resource)
    end
  end

  defp write_archipelago_payload!(dir, dataset, first_record, remaining_records) do
    payload = %{
      provider: dataset.provider,
      retrieved_at: dataset.retrieved_at,
      license_note: dataset.license_note,
      provider_permissions: dataset.provider_permissions,
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
      provider_permissions: dataset.provider_permissions,
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
    record = unique_title_record!(dataset.records)

    remaining_records =
      Enum.reject(dataset.records, &(&1.source_product_id == record.source_product_id))

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
      |> put_field_sources(dataset, ["description", "editorial_praise", "storefront_url"])

    payload = %{
      provider: dataset.provider,
      retrieved_at: dataset.retrieved_at,
      license_note: dataset.license_note,
      provider_permissions: dataset.provider_permissions,
      records: [prose_record | remaining_records]
    }

    File.write!(Path.join(tmp, "archipelago_books.json"), Jason.encode!(payload, pretty: true))
    tmp
  end

  defp put_field_sources(record, dataset, fields) do
    source = %{
      provider: dataset.provider,
      source_uri: record.source_uri,
      source_type: "publisher_dataset",
      rights_basis: dataset.license_note
    }

    Map.update!(record, :field_sources, fn sources ->
      Enum.reduce(fields, sources, fn field, sources -> Map.put(sources, field, source) end)
    end)
  end

  defp archipelago_record_count do
    archipelago_dataset!().records |> length()
  end

  defp archipelago_cover_count do
    archipelago_dataset!().records |> Enum.count(&cover_record?/1)
  end

  defp archipelago_dataset! do
    {:ok, dataset} = Dataset.load_file(Path.join(Dataset.default_dir(), "archipelago_books.json"))
    dataset
  end

  defp count_cover_records(datasets) do
    datasets
    |> Enum.flat_map(& &1.records)
    |> Enum.count(&cover_record?/1)
  end

  defp cover_record?(record) do
    cover = Map.get(record, :cover) || %{}
    is_binary(Map.get(cover, :source_url)) and Map.get(cover, :source_url) != ""
  end

  defp provider_record_count(datasets, provider) do
    datasets
    |> Enum.find(&(&1.provider == provider))
    |> Map.fetch!(:records)
    |> length()
  end

  defp unique_title_record!(records) do
    title_counts = Enum.frequencies_by(records, & &1.work.title)

    Enum.find(records, &(Map.fetch!(title_counts, &1.work.title) == 1)) ||
      raise "expected at least one unique-title record"
  end
end
