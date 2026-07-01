defmodule Hiraeth.Ingestion.RecordCandidateDiffTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Ingestion.RecordCandidate
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @catalog_writer IngestionFixtures.catalog_writer()

  test "fingerprint is stable regardless of map key ordering" do
    candidate_payload_a = %{
      "title" => "Fixture Book",
      "publisher_name" => "Deep Vellum",
      "contributors" => [
        %{"role" => "author", "name" => "Fixture Author"}
      ],
      "isbn_13" => "9781646050001"
    }

    candidate_payload_b = %{
      "isbn_13" => "9781646050001",
      "contributors" => [
        %{"name" => "Fixture Author", "role" => "author"}
      ],
      "publisher_name" => "Deep Vellum",
      "title" => "Fixture Book"
    }

    assert RecordCandidate.fingerprint_for!(candidate_payload_a) ==
             RecordCandidate.fingerprint_for!(candidate_payload_b)

    first =
      IngestionFixtures.create_candidate!(%{
        suffix: "fingerprint-a",
        candidate_identity: "deep-vellum:fingerprint:isbn:9781646050001:a",
        normalized_metadata: candidate_payload_a
      })

    second =
      IngestionFixtures.create_candidate!(%{
        suffix: "fingerprint-b",
        candidate_identity: "deep-vellum:fingerprint:isbn:9781646050001:b",
        normalized_metadata: candidate_payload_b
      })

    assert first.fingerprint == second.fingerprint
    assert String.starts_with?(first.fingerprint, "sha256:")
  end

  test "removed and destructive diffs default to quarantine with pending review" do
    removed =
      IngestionFixtures.create_candidate!(%{
        suffix: "removed",
        diff_classification: "removed",
        review_decision: "approved",
        quarantine_status: "clear",
        review_status: "accepted"
      })

    destructive =
      IngestionFixtures.create_candidate!(%{
        suffix: "destructive",
        diff_classification: "destructive"
      })

    assert removed.diff_classification == "removed"
    assert removed.quarantine_status == "quarantined"
    assert removed.review_decision == "pending_review"
    assert removed.review_status == "quarantined"

    assert destructive.quarantine_status == "quarantined"
    assert destructive.review_decision == "pending_review"
    assert destructive.review_status == "quarantined"
  end

  test "approved candidates can be selected for apply" do
    pending =
      IngestionFixtures.create_candidate!(%{
        suffix: "pending-apply",
        diff_classification: "changed"
      })

    approved =
      IngestionFixtures.create_candidate!(%{
        suffix: "approved-apply",
        diff_classification: "changed"
      })
      |> Ash.Changeset.for_update(:approve_for_apply, %{
        reviewer_note: "Approved for catalog apply."
      })
      |> Ash.update!(actor: @catalog_writer)

    approved_for_apply =
      RecordCandidate
      |> Ash.Query.for_read(:approved_for_apply)
      |> Ash.read!(authorize?: false)

    assert Enum.any?(approved_for_apply, &(&1.id == approved.id))
    refute Enum.any?(approved_for_apply, &(&1.id == pending.id))
    assert approved.review_decision == "approved"
    assert approved.quarantine_status == "clear"
  end

  test "invalid diff classifications and non-map candidate payloads are rejected" do
    source = IngestionFixtures.create_provider_source!("malformed")
    run = IngestionFixtures.create_provider_run!(source, "malformed")
    snapshot = IngestionFixtures.create_source_snapshot!(source, run, "malformed")

    attrs =
      IngestionFixtures.candidate_attrs("malformed")
      |> Map.merge(%{
        provider_run_id: run.id,
        source_snapshot_id: snapshot.id
      })

    assert {:error, invalid_diff} =
             RecordCandidate
             |> Ash.Changeset.for_create(
               :create,
               Map.put(attrs, :diff_classification, "surprise_delete")
             )
             |> Ash.create(actor: @catalog_writer)

    assert Exception.message(invalid_diff) =~ "expected one of"

    assert {:error, invalid_payload} =
             RecordCandidate
             |> Ash.Changeset.for_create(
               :create,
               Map.put(attrs, :normalized_metadata, ["not", "a", "map"])
             )
             |> Ash.create(actor: @catalog_writer)

    assert Exception.message(invalid_payload) =~ "must be a map"
  end
end
