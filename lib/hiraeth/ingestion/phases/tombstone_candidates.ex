defmodule Hiraeth.Ingestion.Phases.TombstoneCandidates do
  @moduledoc """
  Records explicit tombstone provenance for approved removal candidates.

  Tombstones are append-only `SourceRecord` rows with `publisher_tombstone`
  source type. They do not delete catalog rows; replay can inspect them beside
  snapshots and candidate decisions.
  """

  alias Hiraeth.Imports.ImportRun
  alias Hiraeth.Ingestion.RecordCandidate
  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.Sources.{SourceLedgerEntry, SourceRecord}

  require Ash.Query

  def run(%{provider_run_id: run_id, manifest: manifest}, candidates \\ nil) do
    candidates = candidates || candidates_for_run(run_id)
    tombstoneable = Enum.filter(candidates, &tombstoneable?/1)
    import_run = maybe_import_run(manifest, tombstoneable)
    tombstones = Enum.map(tombstoneable, &create_tombstone!(&1, manifest, import_run))

    RunState.mark_phase(run_id, :tombstone_candidates, :succeeded, %{
      candidate_count: length(tombstoneable),
      source_count: length(tombstones),
      message: "Recorded #{length(tombstones)} approved removal tombstones."
    })

    {:ok, tombstones}
  rescue
    error ->
      RunState.mark_phase(run_id, :tombstone_candidates, :failed, %{
        error_count: 1,
        error: %{code: :tombstone_failed, message: Exception.message(error)}
      })

      {:error, {:tombstone_failed, Exception.message(error)}}
  end

  defp candidates_for_run(run_id) do
    RecordCandidate
    |> Ash.Query.filter(provider_run_id == ^run_id)
    |> Ash.read!(authorize?: false)
  end

  defp tombstoneable?(%RecordCandidate{} = candidate) do
    candidate.diff_classification == "removed" and candidate.review_decision == "approved" and
      candidate.quarantine_status == "clear"
  end

  defp maybe_import_run(_manifest, []), do: nil

  defp maybe_import_run(manifest, candidates) do
    ImportRun
    |> Ash.Changeset.for_create(:create, %{
      provider: manifest.provider,
      status: "applied",
      row_limit: length(candidates)
    })
    |> Ash.create!(actor: RunState.catalog_writer())
  end

  defp create_tombstone!(candidate, manifest, import_run) do
    checksum = tombstone_checksum(candidate)

    source_record =
      SourceRecord
      |> Ash.Changeset.for_create(:create, %{
        provider: manifest.provider,
        source_type: "publisher_tombstone",
        source_uri: candidate.source_uri,
        file_checksum: checksum,
        license_note: manifest.permission_basis || "approved removal candidate tombstone",
        source_identity: candidate.candidate_identity,
        raw_payload: tombstone_payload(candidate),
        imported_at: DateTime.utc_now(:second),
        import_run_id: import_run && import_run.id
      })
      |> Ash.create!(actor: RunState.catalog_writer())

    SourceLedgerEntry
    |> Ash.Changeset.for_create(:create, %{
      source_record_id: source_record.id,
      event_type: "ingestion_tombstone_recorded",
      message:
        "Recorded approved removal tombstone for #{candidate.candidate_identity}; no catalog rows were deleted.",
      occurred_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: RunState.catalog_writer())

    source_record
  end

  defp tombstone_payload(candidate) do
    %{
      "candidate_id" => candidate.id,
      "candidate_identity" => candidate.candidate_identity,
      "diff_classification" => candidate.diff_classification,
      "fingerprint" => candidate.fingerprint,
      "previous_fingerprint" => candidate.previous_fingerprint,
      "review_decision" => candidate.review_decision,
      "source_snapshot_id" => candidate.source_snapshot_id,
      "removed_payload" => candidate.normalized_metadata
    }
  end

  defp tombstone_checksum(candidate) do
    candidate
    |> tombstone_payload()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
