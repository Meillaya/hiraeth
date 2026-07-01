defmodule Hiraeth.Ingestion.Phases.ReplaySnapshot do
  @moduledoc """
  Reconstructs replayable records from approved candidates or a retained source
  snapshot without fabricating new provenance.
  """

  alias Hiraeth.Ingestion.{RecordCandidate, SourceSnapshot}
  alias Hiraeth.Ingestion.Phases.RunState

  require Ash.Query

  def run(%{provider_run_id: run_id} = context) do
    records = approved_candidate_records(run_id)

    RunState.mark_phase(run_id, :replay_snapshot, :succeeded, %{
      source_count: length(records),
      message: "Prepared #{length(records)} replay records from approved candidate payloads."
    })

    {:ok, Map.put(context, :replay_records, records)}
  rescue
    error ->
      RunState.mark_phase(context.provider_run_id, :replay_snapshot, :failed, %{
        error_count: 1,
        error: %{code: :replay_failed, message: Exception.message(error)}
      })

      {:error, {:replay_failed, Exception.message(error)}}
  end

  def from_snapshot(%SourceSnapshot{} = snapshot) do
    snapshot
    |> SourceSnapshot.load_payload!()
    |> Jason.decode!()
    |> Map.get("records", [])
  end

  defp approved_candidate_records(run_id) do
    RecordCandidate
    |> Ash.Query.filter(
      provider_run_id == ^run_id and review_decision == "approved" and
        quarantine_status == "clear"
    )
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&(&1.diff_classification in ["removed", "destructive", "invalid"]))
    |> Enum.map(&candidate_replay_payload/1)
  end

  defp candidate_replay_payload(%RecordCandidate{} = candidate) do
    Map.put(candidate.normalized_metadata, "ingestion_candidate", %{
      "candidate_id" => candidate.id,
      "candidate_identity" => candidate.candidate_identity,
      "provider_run_id" => candidate.provider_run_id,
      "source_snapshot_id" => candidate.source_snapshot_id,
      "diff_classification" => candidate.diff_classification,
      "fingerprint" => candidate.fingerprint,
      "review_decision" => candidate.review_decision
    })
  end
end
