defmodule Hiraeth.TestSupport.ApplyPhaseRegressionHelpers do
  @moduledoc false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Ingestion.{ProviderManifest, RecordCandidate}
  alias Hiraeth.RealCatalog.SourceIdentity
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}
  alias Hiraeth.TestSupport.IngestionFixtures

  @manifest_path Path.join([
                   File.cwd!(),
                   "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                 ])

  def setup_context(suffix) do
    clear_catalog!()
    Application.delete_env(:hiraeth, :importer)

    source = IngestionFixtures.create_provider_source!(suffix)
    run = IngestionFixtures.create_provider_run!(source, suffix)
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, suffix)
    manifest = ProviderManifest.load!(@manifest_path)

    %{source: source, run: run, snapshot: snapshot, manifest: manifest}
  end

  def context(run, manifest), do: %{provider_run_id: run.id, manifest: manifest}

  def payload_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))

  def approved_candidate!(run, snapshot, suffix) do
    create_candidate!(run, snapshot, suffix, %{})
  end

  def removed_candidate!(run, snapshot, suffix, attrs \\ %{}) do
    create_candidate!(run, snapshot, suffix, Map.merge(%{diff_classification: "removed"}, attrs))
  end

  def create_candidate!(run, snapshot, suffix, attrs) do
    metadata = catalog_record(suffix)

    attrs =
      Map.merge(
        %{
          provider_run_id: run.id,
          source_snapshot_id: snapshot.id,
          candidate_identity: SourceIdentity.for_record("test_publisher_api", metadata),
          record_type: "edition",
          review_status: "accepted",
          source_uri: metadata["source_uri"],
          diff_classification: "new",
          quarantine_status: "clear",
          review_decision: "approved",
          raw_metadata: metadata,
          normalized_metadata: metadata,
          validation_errors: [],
          validation_findings: []
        },
        attrs
      )

    RecordCandidate
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  def source_record!(provider, suffix, checksum) do
    SourceRecord
    |> Ash.Changeset.for_create(:create, %{
      provider: provider,
      source_type: "publisher_dataset",
      source_uri: "https://www.testpublisher.com/books/#{suffix}",
      file_checksum: checksum,
      license_note: "fixture prior source",
      source_identity: "#{provider}:stale:#{suffix}",
      raw_payload:
        Map.put(catalog_record(suffix), "source_identity", "#{provider}:stale:#{suffix}"),
      imported_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  def ledger_entry!(source_record, message) do
    SourceLedgerEntry
    |> Ash.Changeset.for_create(:create, %{
      source_record_id: source_record.id,
      event_type: "preexisting",
      message: message,
      occurred_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  def catalog_record(suffix) do
    %{
      "source_uri" => "https://www.testpublisher.com/books/#{suffix}",
      "publisher" => "Test Publisher",
      "source_product_id" => "apply-phase-#{suffix}",
      "source_sku" => nil,
      "imprint" => nil,
      "description" => nil,
      "synopsis" => nil,
      "storefront_url" => nil,
      "missing_fields" => %{},
      "work" => work_payload(suffix),
      "edition" => edition_payload(suffix),
      "contributors" => [%{"name" => "Apply Author", "role" => "author"}],
      "curation" => %{"status" => "approved"},
      "displayed_fields" => ["title", "contributors", "publisher", "isbn_13"],
      "field_sources" => field_sources(suffix),
      "cover" => %{},
      "no_cover_reason" => "fixture has no cover",
      "series" => [],
      "review_links" => [],
      "editorial_praise" => []
    }
  end

  defp work_payload(suffix) do
    %{
      "title" => "Apply Phase Book #{suffix}",
      "subtitle" => nil,
      "original_title" => nil,
      "original_language_code" => nil,
      "subjects" => nil,
      "publication_state" => "published"
    }
  end

  defp edition_payload(suffix) do
    %{
      "title" => "Apply Phase Book #{suffix}",
      "subtitle" => nil,
      "format" => "paperback",
      "language_code" => nil,
      "page_count" => nil,
      "dimensions" => nil,
      "published_on" => nil,
      "isbn_13" => "978164605#{suffix_code(suffix)}"
    }
  end

  defp field_sources(suffix) do
    for field <- ~w(title contributors publisher isbn_13), into: %{} do
      {field,
       %{
         "provider" => "test_publisher_api",
         "source_uri" => "https://www.testpublisher.com/books/#{suffix}",
         "source_type" => "publisher_dataset"
       }}
    end
  end

  defp suffix_code(suffix) do
    suffix
    |> :erlang.phash2(9000)
    |> Kernel.+(1000)
    |> Integer.to_string()
  end

  defp clear_catalog! do
    [
      SourceLedgerEntry,
      SourceRecord,
      Hiraeth.Covers.CoverAssignment,
      Hiraeth.Covers.CoverAsset,
      Identifier,
      Hiraeth.Catalog.Contribution,
      Edition,
      Hiraeth.Catalog.SeriesMembership,
      Hiraeth.Catalog.Series,
      Work,
      Hiraeth.Catalog.Imprint,
      Publisher
    ]
    |> Enum.each(&Hiraeth.Repo.delete_all/1)
  end
end
