defmodule Hiraeth.Ingestion.Phases.ValidateCandidates do
  @moduledoc """
  Validates normalized records as replayable candidates without applying them.
  """

  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.RealCatalog.Validator

  def run(
        %{
          manifest: manifest,
          manifest_path: manifest_path,
          normalized_records: records,
          provider_run_id: run_id
        } = context
      ) do
    dataset = dataset(manifest, manifest_path, records)

    with :ok <- validate_expected_record_count(records, manifest),
         {:ok, _summary} <- Validator.validate_datasets([dataset]) do
      RunState.mark_phase(run_id, :validate_candidates, :succeeded, %{
        source_count: length(records)
      })

      {:ok, Map.put(context, :dataset, dataset)}
    else
      {:error, reason} ->
        RunState.mark_phase(run_id, :validate_candidates, :failed, %{
          error_count: 1,
          error: %{code: :validation_failed, message: inspect(reason)}
        })

        {:error, reason}
    end
  end

  defp dataset(manifest, manifest_path, records) do
    %{
      provider: manifest.provider,
      records: records,
      file: Path.basename(manifest_path),
      file_path: manifest_path,
      file_checksum: ProviderIngestionWorker.compute_file_checksum(records),
      license_note: "sidecar_import",
      provider_permissions: %{
        provider: manifest.provider,
        permission_basis: manifest.permission_basis,
        cover_cache_policy: manifest.cover_cache_policy,
        takedown_contact: manifest.takedown_contact,
        not_legal_advice: manifest.not_legal_advice,
        source_urls: manifest.source_urls,
        source_hosts: manifest.source_hosts,
        cover_hosts: manifest.cover_hosts,
        excluded_content: manifest.excluded_content
      }
    }
  end

  defp validate_expected_record_count(records, manifest) do
    expected = manifest.expected_record_count
    actual = length(records)

    if is_integer(expected) and expected != actual do
      {:error, "expected_record_count #{expected} does not match fetched record count #{actual}"}
    else
      :ok
    end
  end
end
