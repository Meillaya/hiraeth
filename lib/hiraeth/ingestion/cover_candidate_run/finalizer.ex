defmodule Hiraeth.Ingestion.CoverCandidateRun.Finalizer do
  @moduledoc false

  alias Hiraeth.Ingestion.Telemetry

  @catalog_writer %{id: "provider-ingestion-worker", catalog_write?: true}

  def emit_legacy_cover_cache(status, cover_urls, cover_paths, failed_covers, manifest) do
    Telemetry.cover_cache(status, legacy_cover_counts(cover_urls, cover_paths, failed_covers), %{
      provider: manifest.provider
    })
  end

  def mark_succeeded!(provider_run, candidates, summary) do
    counts = run_counts(candidates, summary)

    Telemetry.cover_cache(:succeeded, cover_telemetry_counts(counts), %{
      provider_run_id: provider_run.id,
      provider_source_id: provider_run.provider_source_id
    })

    provider_run
    |> Ash.Changeset.for_update(
      :mark_succeeded,
      Map.put(counts, :finished_at, DateTime.utc_now(:second))
    )
    |> Ash.update!(actor: @catalog_writer)
  end

  def mark_failed!(provider_run, candidates, failures) do
    failed_count = failed_count_from_candidates(candidates)
    error_count = max(length(List.wrap(failures)), failed_count)

    Telemetry.cover_cache(
      :failed,
      %{
        candidate_count: length(candidates),
        cached_count: accepted_count_from_candidates(candidates),
        failed_count: failed_count,
        error_count: error_count
      },
      %{
        provider_run_id: provider_run.id,
        provider_source_id: provider_run.provider_source_id
      }
    )

    provider_run
    |> Ash.Changeset.for_update(:mark_failed, %{
      finished_at: DateTime.utc_now(:second),
      source_count: 1,
      snapshot_count: 1,
      candidate_count: length(candidates),
      accepted_count: accepted_count_from_candidates(candidates),
      rejected_count: failed_count,
      error_count: error_count
    })
    |> Ash.update!(actor: @catalog_writer)
  end

  defp legacy_cover_counts(cover_urls, cover_paths, failed_covers) do
    failed_count = length(List.wrap(failed_covers))

    %{
      candidate_count: length(cover_urls),
      cached_count: cached_cover_count(cover_paths),
      failed_count: failed_count,
      error_count: failed_count
    }
  end

  defp cached_cover_count(cover_paths) when is_map(cover_paths), do: map_size(cover_paths)
  defp cached_cover_count(cover_paths) when is_list(cover_paths), do: length(cover_paths)
  defp cached_cover_count(_cover_paths), do: 0

  defp run_counts(candidates, summary) when is_map(summary) do
    failed_count =
      Map.get(
        summary,
        :failed,
        Map.get(summary, "failed", failed_count_from_candidates(candidates))
      )

    cached_count =
      Map.get(
        summary,
        :cached,
        Map.get(summary, "cached", accepted_count_from_candidates(candidates))
      )

    %{
      source_count: 1,
      snapshot_count: 1,
      candidate_count: length(candidates),
      accepted_count: cached_count,
      rejected_count: failed_count,
      error_count: failed_count
    }
  end

  defp run_counts(candidates, _summary) do
    failed_count = failed_count_from_candidates(candidates)

    %{
      source_count: 1,
      snapshot_count: 1,
      candidate_count: length(candidates),
      accepted_count: accepted_count_from_candidates(candidates),
      rejected_count: failed_count,
      error_count: failed_count
    }
  end

  defp cover_telemetry_counts(counts) do
    %{
      candidate_count: Map.get(counts, :candidate_count, 0),
      cached_count: Map.get(counts, :accepted_count, 0),
      failed_count: Map.get(counts, :rejected_count, 0),
      error_count: Map.get(counts, :error_count, 0)
    }
  end

  defp accepted_count_from_candidates(candidates) do
    Enum.count(candidates, &(&1.review_status == "accepted"))
  end

  defp failed_count_from_candidates(candidates) do
    Enum.count(candidates, &(&1.review_status in ["rejected", "quarantined"]))
  end
end
