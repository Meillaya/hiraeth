defmodule Hiraeth.TestSupport.IngestionFixtures do
  @moduledoc false

  alias Hiraeth.Ingestion.{ProviderRun, ProviderSource, RecordCandidate, SourceSnapshot}

  @catalog_writer %{id: "catalog-writer-fixture", catalog_write?: true}
  @fetched_at ~U[2026-06-01 12:00:00Z]

  def catalog_writer, do: @catalog_writer

  def create_candidate!(attrs \\ %{}) do
    suffix = Map.get(attrs, :suffix, "fixture")
    source = create_provider_source!(suffix)
    run = create_provider_run!(source, suffix)
    snapshot = create_source_snapshot!(source, run, suffix)

    attrs =
      attrs
      |> Map.delete(:suffix)
      |> Map.merge(%{
        provider_run_id: run.id,
        source_snapshot_id: snapshot.id
      })

    RecordCandidate
    |> Ash.Changeset.for_create(:create, Map.merge(candidate_attrs(suffix), attrs))
    |> Ash.create!(actor: @catalog_writer)
  end

  def create_provider_source!(suffix \\ "fixture") do
    ProviderSource
    |> Ash.Changeset.for_create(:create, %{
      stable_source_key: "publisher:deep-vellum:#{suffix}:manifest",
      provider_name: "Deep Vellum #{suffix}",
      source_kind: "publisher",
      ingestion_mode: "manifest",
      base_uri: "https://www.deepvellum.org/",
      manifest_uri: "https://www.deepvellum.org/catalog-#{suffix}.json",
      allowed_hosts: ["www.deepvellum.org"],
      rate_limit_per_minute: 30,
      max_bytes: 1_048_576,
      checksum_algorithm: "sha256",
      required_checksum: "sha256:provider-manifest-#{suffix}",
      license_note: "Official publisher catalog metadata linked to purchase pages.",
      enabled?: true
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  def create_provider_run!(source, suffix \\ "fixture") do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      status: "queued",
      requested_by: "mix hiraeth.ingest_provider",
      run_key: "deep-vellum-#{suffix}-2026-06-01T12:00:00Z",
      provenance: %{"manifest_uri" => "https://www.deepvellum.org/catalog-#{suffix}.json"}
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  def create_source_snapshot!(source, run, suffix \\ "fixture") do
    SourceSnapshot
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      provider_run_id: run.id,
      source_uri: "https://www.deepvellum.org/catalog-#{suffix}.json",
      content_checksum: "sha256:snapshot-#{suffix}",
      fetched_at: @fetched_at,
      http_status: 200,
      content_type: "application/json",
      byte_size: 512,
      raw_payload: %{"books" => [%{"title" => "Fixture Book #{suffix}"}]},
      storage_ref: "snapshots/deep-vellum/#{suffix}/catalog.json"
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  def candidate_attrs(suffix \\ "fixture") do
    %{
      candidate_identity: "deep-vellum:#{suffix}:isbn:9781646050001",
      record_type: "edition",
      source_uri: "https://www.deepvellum.org/book/fixture-book-#{suffix}/",
      raw_metadata: %{
        "title" => "Fixture Book #{suffix}",
        "isbn" => "9781646050001",
        "publisher" => "Deep Vellum"
      },
      normalized_metadata: normalized_metadata(suffix),
      validation_errors: [],
      validation_findings: []
    }
  end

  def normalized_metadata(suffix \\ "fixture") do
    %{
      "title" => "Fixture Book #{suffix}",
      "isbn_13" => "9781646050001",
      "publisher_name" => "Deep Vellum",
      "contributors" => [
        %{"name" => "Fixture Author", "role" => "author"}
      ]
    }
  end
end
