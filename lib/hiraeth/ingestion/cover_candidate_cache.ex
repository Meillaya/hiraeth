defmodule Hiraeth.Ingestion.CoverCandidateCache do
  @moduledoc false

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, RecordCandidate}

  @catalog_writer %{id: "cover-pipeline", catalog_write?: true}

  def cover_record_candidate?(%RecordCandidate{record_type: "cover"}), do: true
  def cover_record_candidate?(_candidate), do: false

  def cover_from_candidate(%RecordCandidate{} = candidate) do
    metadata = candidate.normalized_metadata || %{}

    %{
      source_url: string_map_value(metadata, "source_url") || candidate.source_uri,
      provider: string_map_value(metadata, "provider"),
      rights_basis: string_map_value(metadata, "rights_basis") || "local_cache_permitted",
      attribution_text: string_map_value(metadata, "attribution_text"),
      allowed_cover_hosts: string_map_value(metadata, "allowed_cover_hosts") || []
    }
  end

  def mark_cached!(%RecordCandidate{} = candidate, cached_path, thumbnail_path) do
    cover_cache = %{
      "status" => "cached",
      "retry_state" => "complete",
      "cached_file_path" => cached_path,
      "thumbnail_file_path" => thumbnail_path,
      "source_snapshot_id" => candidate.source_snapshot_id,
      "record_candidate_id" => candidate.id,
      "cached_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
    }

    updated =
      candidate
      |> Ash.Changeset.for_update(:update, %{
        review_status: "accepted",
        quarantine_status: "clear",
        review_decision: "approved",
        validation_errors: [],
        validation_findings: [],
        normalized_metadata: put_cover_cache_metadata(candidate, cover_cache)
      })
      |> Ash.update!(actor: @catalog_writer)

    append_event!(updated, "succeeded", "cover candidate cached", %{
      "record_candidate_id" => candidate.id,
      "cached_file_path" => cached_path,
      "thumbnail_file_path" => thumbnail_path
    })

    updated
  end

  def mark_failed!(%RecordCandidate{} = candidate, reason) do
    reason = to_string(reason)
    retry_state = failure_retry_state(reason)

    cover_cache = %{
      "status" => "quarantined",
      "retry_state" => retry_state,
      "failure_reason" => reason,
      "source_snapshot_id" => candidate.source_snapshot_id,
      "record_candidate_id" => candidate.id,
      "failed_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
    }

    updated =
      candidate
      |> Ash.Changeset.for_update(:update, %{
        review_status: "quarantined",
        quarantine_status: "quarantined",
        review_decision: "pending_review",
        validation_errors: [reason],
        validation_findings: [
          %{
            "category" => "cover_cache",
            "severity" => "error",
            "retry_state" => retry_state,
            "message" => reason
          }
        ],
        normalized_metadata: put_cover_cache_metadata(candidate, cover_cache)
      })
      |> Ash.update!(actor: @catalog_writer)

    append_event!(updated, "failed", "cover candidate quarantined", %{
      "record_candidate_id" => candidate.id,
      "retry_state" => retry_state,
      "reason" => reason
    })

    updated
  end

  def failure_summary({:error, %RecordCandidate{} = candidate, reason}) do
    reason = to_string(reason)

    %{
      record_candidate_id: candidate.id,
      source_snapshot_id: candidate.source_snapshot_id,
      source_url: candidate.source_uri,
      retry_state: failure_retry_state(reason),
      reason: reason
    }
  end

  def failure_retry_state(reason) do
    if String.contains?(reason, "allowlisted") or String.contains?(reason, "HTTPS") do
      "quarantined"
    else
      "retryable"
    end
  end

  defp append_event!(%RecordCandidate{} = candidate, status, message, payload) do
    provider_run = Ash.get!(ProviderRun, candidate.provider_run_id, authorize?: false)

    IngestionEvent
    |> Ash.Changeset.for_create(:create, %{
      provider_run_id: candidate.provider_run_id,
      provider_source_id: provider_run.provider_source_id,
      source_snapshot_id: candidate.source_snapshot_id,
      event_kind: "cover_cache_candidate",
      status: status,
      message: message,
      payload: payload,
      occurred_at: DateTime.utc_now(:second)
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp put_cover_cache_metadata(%RecordCandidate{} = candidate, cover_cache) do
    candidate.normalized_metadata
    |> Map.delete("public_url")
    |> Map.delete(:public_url)
    |> Map.put("cover_cache", cover_cache)
  end

  defp string_map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, atom_metadata_key(key))
  end

  defp string_map_value(_map, _key), do: nil

  defp atom_metadata_key("allowed_cover_hosts"), do: :allowed_cover_hosts
  defp atom_metadata_key("attribution_text"), do: :attribution_text
  defp atom_metadata_key("provider"), do: :provider
  defp atom_metadata_key("rights_basis"), do: :rights_basis
  defp atom_metadata_key("source_url"), do: :source_url
  defp atom_metadata_key(_key), do: nil
end
