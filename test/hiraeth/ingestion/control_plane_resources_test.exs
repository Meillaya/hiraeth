defmodule Hiraeth.Ingestion.ControlPlaneResourcesTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Ingestion.{
    IngestionEvent,
    ProviderRun,
    ProviderSource,
    RecordCandidate,
    SourceSnapshot
  }

  @catalog_writer %{id: "catalog-writer-fixture", catalog_write?: true}
  @fetched_at ~U[2026-06-01 12:00:00Z]
  @started_at ~U[2026-06-01 12:01:00Z]
  @finished_at ~U[2026-06-01 12:02:00Z]

  test "provider sources preserve stable source identity, source metadata, and write policy" do
    source =
      create_provider_source!(%{
        stable_source_key: "publisher:deep-vellum:manifest",
        provider_name: "Deep Vellum",
        source_kind: "publisher",
        ingestion_mode: "manifest",
        base_uri: "https://www.deepvellum.org/",
        manifest_uri: "https://www.deepvellum.org/catalog.json",
        allowed_hosts: ["www.deepvellum.org"],
        rate_limit_per_minute: 30,
        max_bytes: 1_048_576,
        checksum_algorithm: "sha256",
        required_checksum: "sha256:provider-manifest-fixture",
        license_note: "Official publisher catalog metadata linked to purchase pages.",
        enabled?: true
      })

    assert source.stable_source_key == "publisher:deep-vellum:manifest"
    assert source.provider_name == "Deep Vellum"
    assert source.source_kind == "publisher"
    assert source.ingestion_mode == "manifest"
    assert source.base_uri == "https://www.deepvellum.org/"
    assert source.manifest_uri == "https://www.deepvellum.org/catalog.json"
    assert source.allowed_hosts == ["www.deepvellum.org"]
    assert source.rate_limit_per_minute == 30
    assert source.max_bytes == 1_048_576
    assert source.checksum_algorithm == "sha256"
    assert source.required_checksum == "sha256:provider-manifest-fixture"
    assert source.license_note =~ "Official publisher"
    assert source.enabled? == true

    assert {:error, duplicate_error} =
             ProviderSource
             |> Ash.Changeset.for_create(:create, %{
               stable_source_key: "publisher:deep-vellum:manifest",
               provider_name: "Deep Vellum duplicate",
               source_kind: "publisher",
               ingestion_mode: "manifest"
             })
             |> Ash.create(actor: @catalog_writer)

    assert Exception.message(duplicate_error) =~ "has already been taken"

    assert {:error, forbidden_error} =
             ProviderSource
             |> Ash.Changeset.for_create(:create, %{
               stable_source_key: "publisher:unauthorized:manifest",
               provider_name: "Unauthorized",
               source_kind: "publisher",
               ingestion_mode: "manifest"
             })
             |> Ash.create()

    assert Exception.message(forbidden_error) =~ "forbidden"

    updated =
      source
      |> Ash.Changeset.for_update(:update, %{
        rate_limit_per_minute: 15,
        enabled?: false
      })
      |> Ash.update!(actor: @catalog_writer)

    assert updated.rate_limit_per_minute == 15
    assert updated.enabled? == false
    assert Enum.any?(Ash.read!(ProviderSource, authorize?: false), &(&1.id == source.id))
  end

  test "provider runs belong to provider sources and record lifecycle counters and timestamps" do
    source = create_provider_source!()

    queued =
      ProviderRun
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        status: "queued",
        requested_by: "mix hiraeth.ingest_provider",
        run_key: "deep-vellum-2026-06-01T12:00:00Z",
        provenance: %{"manifest_uri" => "https://www.deepvellum.org/catalog.json"}
      })
      |> Ash.create!(actor: @catalog_writer)

    assert queued.provider_source_id == source.id
    assert queued.status == "queued"
    assert queued.requested_by == "mix hiraeth.ingest_provider"
    assert queued.provenance["manifest_uri"] == "https://www.deepvellum.org/catalog.json"

    running =
      queued
      |> Ash.Changeset.for_update(:mark_running, %{
        started_at: @started_at
      })
      |> Ash.update!(actor: @catalog_writer)

    assert running.status == "running"
    assert running.started_at == @started_at

    succeeded =
      running
      |> Ash.Changeset.for_update(:mark_succeeded, %{
        finished_at: @finished_at,
        source_count: 1,
        snapshot_count: 1,
        candidate_count: 2,
        accepted_count: 1,
        rejected_count: 1,
        error_count: 0
      })
      |> Ash.update!(actor: @catalog_writer)

    assert succeeded.status == "succeeded"
    assert succeeded.finished_at == @finished_at
    assert succeeded.source_count == 1
    assert succeeded.snapshot_count == 1
    assert succeeded.candidate_count == 2
    assert succeeded.accepted_count == 1
    assert succeeded.rejected_count == 1
    assert succeeded.error_count == 0

    assert Enum.any?(Ash.read!(ProviderRun, authorize?: false), &(&1.id == queued.id))
  end

  test "source snapshots immutably capture source bytes, checksum, and storage references" do
    source = create_provider_source!()
    run = create_provider_run!(source)

    snapshot =
      SourceSnapshot
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        provider_run_id: run.id,
        source_uri: "https://www.deepvellum.org/catalog.json",
        content_checksum: "sha256:snapshot-fixture",
        fetched_at: @fetched_at,
        http_status: 200,
        content_type: "application/json",
        byte_size: 512,
        raw_payload: %{"books" => [%{"title" => "Fixture Book"}]},
        storage_ref: "snapshots/deep-vellum/2026-06-01/catalog.json"
      })
      |> Ash.create!(actor: @catalog_writer)

    assert snapshot.provider_source_id == source.id
    assert snapshot.provider_run_id == run.id
    assert snapshot.source_uri == "https://www.deepvellum.org/catalog.json"
    assert snapshot.content_checksum == "sha256:snapshot-fixture"
    assert snapshot.fetched_at == @fetched_at
    assert snapshot.http_status == 200
    assert snapshot.content_type == "application/json"
    assert snapshot.byte_size == 512
    assert snapshot.raw_payload == %{"books" => [%{"title" => "Fixture Book"}]}
    assert snapshot.storage_ref == "snapshots/deep-vellum/2026-06-01/catalog.json"

    assert_raise ArgumentError, ~r/No such update action|immutable/i, fn ->
      snapshot
      |> Ash.Changeset.for_update(:update, %{
        raw_payload: %{"books" => [%{"title" => "Mutated Book"}]},
        content_checksum: "sha256:mutated"
      })
      |> Ash.update!(actor: @catalog_writer)
    end

    assert Enum.any?(Ash.read!(SourceSnapshot, authorize?: false), &(&1.id == snapshot.id))
  end

  test "record candidates preserve raw and normalized metadata and support review transitions" do
    source = create_provider_source!()
    run = create_provider_run!(source)
    snapshot = create_source_snapshot!(source, run)

    candidate =
      RecordCandidate
      |> Ash.Changeset.for_create(:create, %{
        provider_run_id: run.id,
        source_snapshot_id: snapshot.id,
        candidate_identity: "deep-vellum:isbn:9781646050001",
        record_type: "edition",
        review_status: "needs_review",
        source_uri: "https://www.deepvellum.org/book/fixture-book/",
        raw_metadata: %{
          "title" => "Fixture Book",
          "isbn" => "9781646050001",
          "publisher" => "Deep Vellum"
        },
        normalized_metadata: %{
          "title" => "Fixture Book",
          "isbn_13" => "9781646050001",
          "publisher_name" => "Deep Vellum"
        },
        validation_errors: ["missing cover checksum"]
      })
      |> Ash.create!(actor: @catalog_writer)

    assert candidate.provider_run_id == run.id
    assert candidate.source_snapshot_id == snapshot.id
    assert candidate.candidate_identity == "deep-vellum:isbn:9781646050001"
    assert candidate.record_type == "edition"
    assert candidate.review_status == "needs_review"
    assert candidate.raw_metadata["isbn"] == "9781646050001"
    assert candidate.normalized_metadata["isbn_13"] == "9781646050001"
    assert candidate.validation_errors == ["missing cover checksum"]

    accepted =
      candidate
      |> Ash.Changeset.for_update(:accept, %{
        reviewer_note: "Official source metadata is sufficient for catalog import."
      })
      |> Ash.update!(actor: @catalog_writer)

    assert accepted.review_status == "accepted"
    assert accepted.reviewer_note =~ "Official source"

    rejected =
      accepted
      |> Ash.Changeset.for_update(:reject, %{
        reviewer_note: "Superseded by newer official metadata."
      })
      |> Ash.update!(actor: @catalog_writer)

    assert rejected.review_status == "rejected"
    assert rejected.reviewer_note =~ "Superseded"
  end

  test "ingestion events are append-only audit records readable for run review" do
    source = create_provider_source!()
    run = create_provider_run!(source)
    snapshot = create_source_snapshot!(source, run)

    event =
      IngestionEvent
      |> Ash.Changeset.for_create(:create, %{
        provider_run_id: run.id,
        provider_source_id: source.id,
        source_snapshot_id: snapshot.id,
        event_kind: "snapshot_fetched",
        status: "succeeded",
        message: "Fetched provider manifest fixture.",
        payload: %{
          "content_checksum" => "sha256:snapshot-fixture",
          "source_uri" => "https://www.deepvellum.org/catalog.json"
        },
        occurred_at: @fetched_at
      })
      |> Ash.create!(actor: @catalog_writer)

    assert event.provider_run_id == run.id
    assert event.provider_source_id == source.id
    assert event.source_snapshot_id == snapshot.id
    assert event.event_kind == "snapshot_fetched"
    assert event.status == "succeeded"
    assert event.message == "Fetched provider manifest fixture."
    assert event.payload["content_checksum"] == "sha256:snapshot-fixture"
    assert event.occurred_at == @fetched_at

    assert Enum.any?(Ash.read!(IngestionEvent, authorize?: false), &(&1.id == event.id))

    assert_raise ArgumentError, ~r/No such update action|append-only/i, fn ->
      event
      |> Ash.Changeset.for_update(:update, %{message: "Mutated audit message."})
      |> Ash.update!(actor: @catalog_writer)
    end
  end

  defp create_provider_source!(attrs \\ %{}) do
    default_attrs = %{
      stable_source_key: "publisher:deep-vellum:manifest",
      provider_name: "Deep Vellum",
      source_kind: "publisher",
      ingestion_mode: "manifest",
      base_uri: "https://www.deepvellum.org/",
      manifest_uri: "https://www.deepvellum.org/catalog.json",
      allowed_hosts: ["www.deepvellum.org"],
      rate_limit_per_minute: 30,
      max_bytes: 1_048_576,
      checksum_algorithm: "sha256",
      required_checksum: "sha256:provider-manifest-fixture",
      license_note: "Official publisher catalog metadata linked to purchase pages.",
      enabled?: true
    }

    ProviderSource
    |> Ash.Changeset.for_create(:create, Map.merge(default_attrs, attrs))
    |> Ash.create!(actor: @catalog_writer)
  end

  defp create_provider_run!(source) do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      status: "queued",
      requested_by: "mix hiraeth.ingest_provider",
      run_key: "deep-vellum-2026-06-01T12:00:00Z",
      provenance: %{"manifest_uri" => "https://www.deepvellum.org/catalog.json"}
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp create_source_snapshot!(source, run) do
    SourceSnapshot
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      provider_run_id: run.id,
      source_uri: "https://www.deepvellum.org/catalog.json",
      content_checksum: "sha256:snapshot-fixture",
      fetched_at: @fetched_at,
      http_status: 200,
      content_type: "application/json",
      byte_size: 512,
      raw_payload: %{"books" => [%{"title" => "Fixture Book"}]},
      storage_ref: "snapshots/deep-vellum/2026-06-01/catalog.json"
    })
    |> Ash.create!(actor: @catalog_writer)
  end
end
