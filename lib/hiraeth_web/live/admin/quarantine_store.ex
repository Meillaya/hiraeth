defmodule HiraethWeb.Admin.QuarantineStore do
  @moduledoc false

  alias Hiraeth.Ingestion.{
    IngestionEvent,
    ProviderRun,
    ProviderSource,
    RecordCandidate,
    SourceSnapshot
  }

  require Ash.Query

  @run_limit 20
  @candidate_limit 75
  @export_page_size 50

  def load(params \\ %{}) do
    selected_candidate = get_candidate(params["candidate_id"])

    selected_run_id =
      params["run_id"] || (selected_candidate && selected_candidate.provider_run_id)

    runs = list_runs(selected_run_id)
    selected_run = select_run(runs, selected_run_id)
    candidates = list_candidates(selected_run, selected_candidate)

    %{
      runs: runs,
      selected_run: selected_run,
      candidates: candidates,
      selected_candidate: selected_candidate_in_scope(selected_candidate, candidates),
      counts: counts(candidates)
    }
  end

  def audit_export(run_id) do
    with {:ok, run} <- fetch_run(run_id),
         {:ok, provider} <- fetch_provider(run.provider_source_id) do
      candidates = export_candidates_for_run(run.id)
      events = export_events_for_run(run.id)
      artifacts = export_snapshots_for_run(run.id)
      candidate_ids = Enum.map(candidates, & &1.id)
      snapshot_ids = artifacts |> Enum.map(& &1.id) |> Enum.uniq()

      {:ok,
       %{
         exported_at: DateTime.utc_now(:second),
         metadata:
           export_metadata(run.id, candidate_ids, snapshot_ids, candidates, events, artifacts),
         provider: Map.take(provider, [:id, :provider_name, :stable_source_key]),
         run: Map.take(run, [:id, :status, :run_key, :requested_by, :provenance]),
         candidates: Enum.map(candidates, &candidate_payload/1),
         events: Enum.map(events, &event_payload/1),
         artifacts: Enum.map(artifacts, &snapshot_payload/1)
       }}
    end
  end

  def fetch_candidate(id), do: fetch_resource(RecordCandidate, id, "Candidate was not found.")
  def fetch_run(id), do: fetch_resource(ProviderRun, id, "Provider run was not found.")
  def fetch_provider(id), do: fetch_resource(ProviderSource, id, "Provider source was not found.")

  def candidates_for_run(run_id) do
    RecordCandidate
    |> Ash.Query.filter(provider_run_id == ^run_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@candidate_limit)
    |> Ash.read!(authorize?: false)
  end

  def events_for_run(run_id) do
    IngestionEvent
    |> Ash.Query.filter(provider_run_id == ^run_id)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(@candidate_limit)
    |> Ash.read!(authorize?: false)
  end

  defp list_runs(selected_run_id) do
    runs =
      ProviderRun
      |> Ash.Query.sort(started_at: :desc, inserted_at: :desc)
      |> Ash.Query.limit(@run_limit)
      |> Ash.read!(authorize?: false)

    selected_run_id
    |> get_run()
    |> prepend_missing(runs)
    |> Enum.sort_by(
      &(&1.started_at || &1.inserted_at || DateTime.from_unix!(0)),
      {:desc, DateTime}
    )
  end

  defp list_candidates(nil, selected), do: prepend_missing(selected, quarantined_candidates())
  defp list_candidates(run, selected), do: prepend_missing(selected, candidates_for_run(run.id))

  defp quarantined_candidates do
    RecordCandidate
    |> Ash.Query.filter(quarantine_status == "quarantined" or review_decision == "pending_review")
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@candidate_limit)
    |> Ash.read!(authorize?: false)
  end

  defp export_candidates_for_run(run_id) do
    paged_read(fn offset ->
      RecordCandidate
      |> Ash.Query.filter(provider_run_id == ^run_id)
      |> Ash.Query.sort(inserted_at: :desc, id: :asc)
      |> Ash.Query.limit(@export_page_size)
      |> Ash.Query.offset(offset)
    end)
  end

  defp export_events_for_run(run_id) do
    paged_read(fn offset ->
      IngestionEvent
      |> Ash.Query.filter(provider_run_id == ^run_id)
      |> Ash.Query.sort(occurred_at: :desc, id: :asc)
      |> Ash.Query.limit(@export_page_size)
      |> Ash.Query.offset(offset)
    end)
  end

  defp export_snapshots_for_run(run_id) do
    paged_read(fn offset ->
      SourceSnapshot
      |> Ash.Query.filter(provider_run_id == ^run_id)
      |> Ash.Query.sort(fetched_at: :desc, id: :asc)
      |> Ash.Query.limit(@export_page_size)
      |> Ash.Query.offset(offset)
    end)
  end

  defp paged_read(query_fun), do: do_paged_read(query_fun, 0, [])

  defp do_paged_read(query_fun, offset, pages) do
    page = query_fun.(offset) |> Ash.read!(authorize?: false)
    pages = [page | pages]

    if length(page) < @export_page_size do
      pages |> Enum.reverse() |> List.flatten()
    else
      do_paged_read(query_fun, offset + @export_page_size, pages)
    end
  end

  defp export_metadata(run_id, candidate_ids, snapshot_ids, candidates, events, artifacts) do
    %{
      export_version: 1,
      complete?: true,
      truncated?: false,
      warnings: [],
      page_size: @export_page_size,
      filters: %{
        provider_run_id: run_id,
        candidate_ids: candidate_ids,
        source_snapshot_ids: snapshot_ids
      },
      row_counts: %{
        candidates: length(candidates),
        events: length(events),
        artifacts: length(artifacts)
      }
    }
  end

  defp select_run([], _), do: nil
  defp select_run(runs, nil), do: List.first(runs)

  defp select_run(runs, id),
    do: Enum.find(runs, &(to_string(&1.id) == to_string(id))) || List.first(runs)

  defp selected_candidate_in_scope(nil, _), do: nil

  defp selected_candidate_in_scope(candidate, candidates),
    do: Enum.find(candidates, &(&1.id == candidate.id))

  defp prepend_missing(nil, list), do: list

  defp prepend_missing(item, list),
    do: if(Enum.any?(list, &(&1.id == item.id)), do: list, else: [item | list])

  defp counts(candidates) do
    %{
      total: length(candidates),
      pending: Enum.count(candidates, &(&1.review_decision == "pending_review")),
      destructive:
        Enum.count(candidates, &RecordCandidate.destructive_diff?(&1.diff_classification))
    }
  end

  defp get_candidate(nil), do: nil
  defp get_candidate(id), do: id |> fetch_candidate() |> unwrap()
  defp get_run(nil), do: nil
  defp get_run(id), do: id |> fetch_run() |> unwrap()
  defp unwrap({:ok, record}), do: record
  defp unwrap(_), do: nil

  defp fetch_resource(_resource, id, message) when id in [nil, ""], do: {:error, message}

  defp fetch_resource(resource, id, message) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, nil} -> {:error, message}
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:error, message}
    end
  rescue
    _ -> {:error, message}
  end

  defp candidate_payload(candidate) do
    Map.take(candidate, [
      :id,
      :candidate_identity,
      :record_type,
      :source_uri,
      :diff_classification,
      :quarantine_status,
      :review_decision,
      :reviewer_note,
      :review_actor_email,
      :reviewed_at,
      :normalized_metadata,
      :validation_errors,
      :validation_findings
    ])
  end

  defp event_payload(event),
    do: Map.take(event, [:id, :event_kind, :status, :message, :payload, :occurred_at])

  defp snapshot_payload(snapshot),
    do:
      Map.take(snapshot, [
        :id,
        :source_uri,
        :content_checksum,
        :storage_ref,
        :artifact_path,
        :byte_size,
        :content_type
      ])
end
