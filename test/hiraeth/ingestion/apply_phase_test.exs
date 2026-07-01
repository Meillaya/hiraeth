defmodule Hiraeth.Ingestion.ApplyPhaseTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Catalog.{Edition, Identifier, Publisher, Work}
  alias Hiraeth.Ingestion.{IngestionEvent, Phases, ProviderManifest, ProviderRun, RecordCandidate}
  alias Hiraeth.Sources.SourceRecord
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @moduletag :capture_log
  @manifest_path Path.join([
                   File.cwd!(),
                   "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                 ])

  setup do
    clear_catalog!()

    source = IngestionFixtures.create_provider_source!("apply-phase")
    run = IngestionFixtures.create_provider_run!(source, "apply-phase")
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, "apply-phase")
    manifest = ProviderManifest.load!(@manifest_path)

    %{source: source, run: run, snapshot: snapshot, manifest: manifest}
  end

  test "happy apply imports only approved clear candidates and audit emits phase event", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    approved_candidate!(run, snapshot, "happy")

    assert {:ok, applied} = Phases.ApplyCandidates.run(context(run, manifest))
    assert length(applied.applied_candidates) == 1

    assert [edition] = Ash.read!(Edition, authorize?: false)
    assert edition.title == "Apply Phase Book happy"

    identifiers = Ash.read!(Identifier, authorize?: false)
    assert Enum.any?(identifiers, &(&1.value == "source:test_publisher_api:apply-phase-happy"))

    assert [source_record] = Ash.read!(SourceRecord, authorize?: false)
    assert source_record.provider == manifest.provider
    assert source_record.source_type == "publisher_dataset"
    assert source_record.raw_payload["field_sources"]["title"]["provider"] == manifest.provider

    assert {:ok, audited} = Phases.AuditRun.run(applied)
    assert audited.provenance_audit.missing_provenance == []

    run = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert run.status == "running"
    assert get_in(run.provenance, ["phases", "apply_candidates", "status"]) == "succeeded"
    assert get_in(run.provenance, ["phases", "audit_run", "status"]) == "succeeded"

    events = Ash.read!(IngestionEvent, authorize?: false)
    assert Enum.any?(events, &(&1.event_kind == "phase:apply_candidates"))
    assert Enum.any?(events, &(&1.event_kind == "phase:audit_run"))
  end

  @tag :quarantined_candidate_not_applied
  test "quarantined_candidate_not_applied leaves catalog unchanged", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    quarantined_candidate!(run, snapshot, "quarantined")

    assert {:ok, applied} = Phases.ApplyCandidates.run(context(run, manifest))
    assert applied.applied_candidates == []
    assert length(applied.blocked_candidates) == 1

    assert [] = Ash.read!(Edition, authorize?: false)
    assert [] = Ash.read!(SourceRecord, authorize?: false)

    run = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert get_in(run.provenance, ["phases", "apply_candidates", "status"]) == "succeeded"
    assert run.accepted_count == 0
    assert run.rejected_count == 1
  end

  test "removed candidate records tombstone provenance without deleting catalog rows", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    existing_catalog_row!(manifest.provider)
    removed_candidate!(run, snapshot, "removed")

    assert {:ok, applied} = Phases.ApplyCandidates.run(context(run, manifest))
    assert applied.applied_candidates == []
    assert length(applied.tombstone_records) == 1

    assert [_edition] = Ash.read!(Edition, authorize?: false)

    assert [tombstone] =
             SourceRecord
             |> Ash.Query.filter(source_type == "publisher_tombstone")
             |> Ash.read!(authorize?: false)

    assert tombstone.raw_payload["diff_classification"] == "removed"

    assert tombstone.raw_payload["removed_payload"]["field_sources"]["title"]["provider"] ==
             manifest.provider
  end

  test "replay uses approved candidate payload and keeps provenance fields intact", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    approved_candidate!(run, snapshot, "replay")

    assert {:ok, replayed} = Phases.ReplaySnapshot.run(context(run, manifest))
    assert [record] = replayed.replay_records
    assert record["field_sources"]["title"]["source_uri"] =~ "/replay"

    assert [] = Ash.read!(Edition, authorize?: false)
    assert [] = Ash.read!(SourceRecord, authorize?: false)
  end

  test "apply failure marks phase and run failed without misleading success", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    approved_candidate!(run, snapshot, "broken", %{normalized_metadata: %{"not" => "importable"}})

    assert {:error, _reason} = Phases.ApplyCandidates.run(context(run, manifest))

    run = Ash.get!(ProviderRun, run.id, authorize?: false)
    assert run.status == "failed"
    assert run.error_count == 1
    assert get_in(run.provenance, ["phases", "apply_candidates", "status"]) == "failed"
    assert [] = Ash.read!(Edition, authorize?: false)
  end

  defp context(run, manifest), do: %{provider_run_id: run.id, manifest: manifest}

  defp approved_candidate!(run, snapshot, suffix, attrs \\ %{}) do
    create_candidate!(run, snapshot, suffix, attrs)
  end

  defp quarantined_candidate!(run, snapshot, suffix) do
    create_candidate!(run, snapshot, suffix, %{
      quarantine_status: "quarantined",
      review_status: "quarantined",
      review_decision: "pending_review"
    })
  end

  defp removed_candidate!(run, snapshot, suffix) do
    run
    |> create_candidate!(snapshot, suffix, %{diff_classification: "removed"})
    |> Ash.Changeset.for_update(:approve_for_apply, %{reviewer_note: "explicit removal approval"})
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_candidate!(run, snapshot, suffix, attrs) do
    metadata = Map.get(attrs, :normalized_metadata, catalog_record(suffix))

    base = %{
      provider_run_id: run.id,
      source_snapshot_id: snapshot.id,
      candidate_identity: "test_publisher_api:#{suffix}:9781646051114",
      record_type: "edition",
      review_status: "accepted",
      source_uri: "https://www.testpublisher.com/books/#{suffix}",
      diff_classification: "new",
      quarantine_status: "clear",
      review_decision: "approved",
      raw_metadata: metadata,
      normalized_metadata: metadata,
      validation_errors: [],
      validation_findings: [],
      reviewer_note: "fixture approved"
    }

    RecordCandidate
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs))
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp catalog_record(suffix) do
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
      "work" => %{
        "title" => "Apply Phase Book #{suffix}",
        "subtitle" => nil,
        "original_title" => nil,
        "original_language_code" => nil,
        "subjects" => nil,
        "publication_state" => "published"
      },
      "edition" => %{
        "title" => "Apply Phase Book #{suffix}",
        "subtitle" => nil,
        "format" => "paperback",
        "language_code" => nil,
        "page_count" => nil,
        "dimensions" => nil,
        "published_on" => nil,
        "isbn_13" => "9781646051114"
      },
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

  defp field_sources(suffix) do
    source_uri = "https://www.testpublisher.com/books/#{suffix}"

    for field <- ~w(title contributors publisher isbn_13), into: %{} do
      {field,
       %{
         "provider" => "test_publisher_api",
         "source_uri" => source_uri,
         "source_type" => "publisher_dataset",
         "rights_basis" => "fixture approval"
       }}
    end
  end

  defp existing_catalog_row!(provider) do
    admin = trusted_catalog_actor()

    publisher =
      Publisher
      |> Ash.Changeset.for_create(:create, %{name: "Test Publisher", slug: "test-publisher"})
      |> Ash.create!(actor: admin)

    work =
      Work
      |> Ash.Changeset.for_create(:create, %{
        title: "Existing Apply Phase Book",
        slug: "test-publisher-existing-apply-phase-book",
        publication_state: "published"
      })
      |> Ash.create!(actor: admin)

    edition =
      Edition
      |> Ash.Changeset.for_create(:create, %{
        title: "Existing Apply Phase Book",
        slug: "test-publisher-existing-apply-phase-book-paperback-9781646051114",
        format: "paperback",
        work_id: work.id,
        publisher_id: publisher.id
      })
      |> Ash.create!(actor: admin)

    SourceRecord
    |> Ash.Changeset.for_create(:create, %{
      provider: provider,
      source_type: "publisher_dataset",
      source_uri: "https://www.testpublisher.com/books/removed",
      file_checksum: "previous-checksum",
      license_note: "fixture",
      source_identity: "test_publisher_api:removed:9781646051114",
      raw_payload: catalog_record("removed"),
      imported_at: DateTime.utc_now(:second),
      edition_id: edition.id
    })
    |> Ash.create!(actor: admin)

    edition
  end

  defp clear_catalog! do
    [
      Hiraeth.Sources.SourceLedgerEntry,
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
