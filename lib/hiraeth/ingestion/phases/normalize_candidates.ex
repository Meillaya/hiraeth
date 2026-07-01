defmodule Hiraeth.Ingestion.Phases.NormalizeCandidates do
  @moduledoc """
  Normalizes fetched provider records into catalog-shaped candidate payloads.
  """

  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.Ingestion.SidecarClient
  alias Hiraeth.Oban.ProviderIngestionWorker

  def run(%{manifest: manifest, raw_records: records, provider_run_id: run_id} = context) do
    {:ok, normalized_records} =
      ProviderIngestionWorker.normalize_provider_records(records, manifest, sidecar_client())

    RunState.mark_phase(run_id, :normalize_candidates, :succeeded, %{
      source_count: length(normalized_records)
    })

    {:ok, Map.put(context, :normalized_records, normalized_records)}
  rescue
    error ->
      RunState.mark_phase(run_id, :normalize_candidates, :failed, %{
        error_count: 1,
        error: %{code: :normalize_failed, message: Exception.message(error)}
      })

      {:error, {:normalize_failed, Exception.message(error)}}
  end

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end
end
