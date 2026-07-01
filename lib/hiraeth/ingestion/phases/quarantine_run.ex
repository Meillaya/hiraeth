defmodule Hiraeth.Ingestion.Phases.QuarantineRun do
  @moduledoc "Persists an explicit quarantine phase summary for blocked candidates."

  alias Hiraeth.Ingestion.RecordCandidate
  alias Hiraeth.Ingestion.Phases.RunState

  require Ash.Query

  def run(%{provider_run_id: run_id} = context) do
    candidates =
      RecordCandidate
      |> Ash.Query.filter(provider_run_id == ^run_id)
      |> Ash.read!(authorize?: false)

    quarantined = Enum.filter(candidates, &quarantined?/1)

    RunState.mark_phase(run_id, :quarantine_run, :succeeded, %{
      candidate_count: length(candidates),
      rejected_count: length(quarantined),
      quarantine_age_seconds: max_quarantine_age_seconds(quarantined),
      message: "Quarantine phase retained #{length(quarantined)} candidates for review."
    })

    {:ok, Map.put(context, :quarantined_candidates, quarantined)}
  end

  defp quarantined?(candidate) do
    candidate.quarantine_status == "quarantined" or
      candidate.diff_classification in ["invalid", "destructive"]
  end

  defp max_quarantine_age_seconds([]), do: 0

  defp max_quarantine_age_seconds(candidates) do
    now = DateTime.utc_now()

    candidates
    |> Enum.map(fn candidate ->
      case candidate.inserted_at do
        %DateTime{} = inserted_at -> DateTime.diff(now, inserted_at, :second)
        _inserted_at -> 0
      end
    end)
    |> Enum.max()
    |> max(0)
  end
end
