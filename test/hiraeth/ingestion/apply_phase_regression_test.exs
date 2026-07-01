defmodule Hiraeth.Ingestion.ApplyPhaseRegressionTest do
  use Hiraeth.DataCase, async: false

  import Hiraeth.TestSupport.ApplyPhaseRegressionHelpers

  alias Hiraeth.Catalog.Edition
  alias Hiraeth.Ingestion.{IngestionEvent, Phases}
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @moduletag :capture_log

  setup do
    setup_context("apply-regression")
  end

  test "candidate apply honors prune_stale false and preserves unreviewed removed source records",
       %{
         run: run,
         snapshot: snapshot,
         manifest: manifest
       } do
    stale = source_record!(manifest.provider, "stale-unreviewed", "previous-checksum")
    ledger_entry!(stale, "preexisting provenance must survive candidate apply")
    approved_candidate!(run, snapshot, "approved")
    removed_candidate!(run, snapshot, "stale-unreviewed")

    assert {:ok, applied} = Phases.ApplyCandidates.run(context(run, manifest))
    assert length(applied.applied_candidates) == 1
    assert length(applied.blocked_candidates) == 1

    assert Ash.get!(SourceRecord, stale.id, authorize?: false).source_uri == stale.source_uri

    assert Enum.any?(
             Ash.read!(SourceLedgerEntry, authorize?: false),
             &(&1.event_type == "preexisting")
           )

    assert [_edition] = Ash.read!(Edition, authorize?: false)
  end

  test "diff phase matches real importer source identities and only removes actually missing records",
       %{
         source: source,
         run: prior_run,
         snapshot: prior_snapshot,
         manifest: manifest
       } do
    stable_record = put_in(catalog_record("stable-real"), ["edition", "isbn_13"], "9781646051113")
    missing_record = put_in(catalog_record("missing-real"), ["edition", "isbn_13"], nil)

    stable_identity =
      Hiraeth.RealCatalog.SourceIdentity.for_record(manifest.provider, stable_record)

    missing_identity =
      Hiraeth.RealCatalog.SourceIdentity.for_record(manifest.provider, missing_record)

    create_candidate!(prior_run, prior_snapshot, "stable-real", %{
      normalized_metadata: stable_record
    })

    create_candidate!(prior_run, prior_snapshot, "missing-real", %{
      normalized_metadata: missing_record
    })

    assert {:ok, _applied} = Phases.ApplyCandidates.run(context(prior_run, manifest))

    stable_source_record =
      SourceRecord
      |> Ash.Query.filter(source_identity == ^stable_identity)
      |> Ash.read!(authorize?: false)
      |> List.first()

    missing_source_record =
      SourceRecord
      |> Ash.Query.filter(source_identity == ^missing_identity)
      |> Ash.read!(authorize?: false)
      |> List.first()

    assert stable_source_record.source_identity == stable_identity
    assert stable_source_record.source_identity == "9781646051113"

    assert missing_source_record.source_identity ==
             "source:#{manifest.provider}:#{missing_record["source_product_id"]}"

    current_run = IngestionFixtures.create_provider_run!(source, "identity-current")

    current_snapshot =
      IngestionFixtures.create_source_snapshot!(source, current_run, "identity-current")

    assert {:ok, diffed} =
             Phases.DiffCandidates.run(%{
               dataset: %{records: [stable_record]},
               manifest: manifest,
               provider_run_id: current_run.id,
               source_snapshot: current_snapshot
             })

    removed_candidates =
      Enum.filter(diffed.record_candidates, &(&1.diff_classification == "removed"))

    refute Enum.any?(
             removed_candidates,
             &(&1.candidate_identity == stable_source_record.source_identity)
           )

    removed =
      Enum.find(
        removed_candidates,
        &(&1.candidate_identity == missing_source_record.source_identity)
      )

    assert removed.quarantine_status == "quarantined"
    assert removed.review_decision == "pending_review"
    assert removed.normalized_metadata["source_product_id"] == missing_record["source_product_id"]
  end

  test "applied source provenance links back to candidate, run, and snapshot", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    candidate = approved_candidate!(run, snapshot, "traceable")

    assert {:ok, _applied} = Phases.ApplyCandidates.run(context(run, manifest))

    [source_record] = Ash.read!(SourceRecord, authorize?: false)
    provenance = source_record.raw_payload["ingestion_candidate"]

    assert payload_value(provenance, "candidate_id") == candidate.id
    assert payload_value(provenance, "candidate_identity") == candidate.candidate_identity
    assert payload_value(provenance, "provider_run_id") == run.id
    assert payload_value(provenance, "source_snapshot_id") == snapshot.id
    assert payload_value(provenance, "fingerprint") == candidate.fingerprint
    assert source_record.import_run_id
  end

  test "approved removal writes tombstone event while unapproved removal does not delete", %{
    run: run,
    snapshot: snapshot,
    manifest: manifest
  } do
    existing = source_record!(manifest.provider, "unapproved-removal", "old-checksum")
    removed_candidate!(run, snapshot, "unapproved-removal")

    assert {:ok, applied} = Phases.ApplyCandidates.run(context(run, manifest))
    assert applied.tombstone_records == []
    assert Ash.get!(SourceRecord, existing.id, authorize?: false)

    assert [] =
             SourceRecord
             |> Ash.Query.filter(source_type == "publisher_tombstone")
             |> Ash.read!(authorize?: false)

    approved =
      removed_candidate!(run, snapshot, "approved-removal", %{
        candidate_identity: "#{manifest.provider}:stale:approved-removal"
      })
      |> Ash.Changeset.for_update(:approve_for_apply, %{
        reviewer_note: "operator approved removal"
      })
      |> Ash.update!(actor: IngestionFixtures.catalog_writer())

    assert {:ok, rerun} = Phases.ApplyCandidates.run(context(run, manifest))
    assert [tombstone] = rerun.tombstone_records
    assert tombstone.raw_payload["candidate_id"] == approved.id
    assert Ash.get!(SourceRecord, existing.id, authorize?: false)

    assert Enum.any?(
             Ash.read!(SourceLedgerEntry, authorize?: false),
             &(&1.event_type == "ingestion_tombstone_recorded")
           )

    assert Enum.any?(
             Ash.read!(IngestionEvent, authorize?: false),
             &(&1.event_kind == "phase:tombstone_candidates")
           )
  end
end
