defmodule Hiraeth.Oban.ProviderIngestionWorker do
  @moduledoc """
  Oban worker that orchestrates full provider ingestion end-to-end.

  This is the core of the ingestion orchestration system. A single job
  processes one provider manifest: fetch/scrape records from the sidecar,
  validate them, cache covers, import into the catalog, and run a
  provenance audit — all-or-nothing.

  ## Unique Job

  Only one job per provider can be enqueued at a time. Duplicate
  enqueues for the same provider are silently rejected.

  ## Idempotency

  The worker checks for existing SourceRecords by provider before
  importing. If records already exist, the import is skipped.

  ## Rate Limiting

  If the sidecar returns a rate-limit error, the job snoozes and
  retries after a delay.
  """

  use Oban.Worker,
    queue: :ingestion,
    unique: [
      keys: [:provider],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: :infinity
    ]

  alias Hiraeth.Ingestion.{
    CoverCandidateRun,
    CoverPipeline,
    Phases,
    ProviderManifest,
    Telemetry
  }

  alias Hiraeth.RealCatalog.SourcePolicy

  require Ash.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, inserted_at: inserted_at}) do
    Telemetry.queue_latency(:provider_ingestion_worker, inserted_at, %{provider: args["provider"]})

    manifest_path = args["manifest_path"]

    with {:ok, manifest} <- load_manifest(manifest_path),
         {:ok, _provider} <- register_provider(manifest_path),
         :ok <- ensure_not_cancelled(args["provider_run_id"]),
         {:ok, phase_context} <- fetch_phase(manifest_path, args),
         {:ok, phase_context} <-
           run_if_not_cancelled(phase_context, &Phases.NormalizeCandidates.run/1),
         {:ok, phase_context} <-
           run_if_not_cancelled(phase_context, &Phases.ValidateCandidates.run/1),
         {:ok, phase_context} <-
           run_if_not_cancelled(phase_context, &Phases.DiffCandidates.run/1),
         {:ok, phase_context} <-
           run_if_not_cancelled(phase_context, &cache_covers_compatibility_phase(&1, manifest)),
         {:ok, phase_context} <- run_if_not_cancelled(phase_context, &Phases.QuarantineRun.run/1),
         {:ok, phase_context} <-
           run_if_not_cancelled(phase_context, &Phases.ApplyCandidates.run/1),
         {:ok, phase_context} <- run_if_not_cancelled(phase_context, &Phases.AuditRun.run/1),
         {:ok, summary} <- finish_if_not_cancelled(phase_context, manifest) do
      {:ok, summary}
    else
      {:cancel, _reason} = cancelled -> cancelled
      other -> other
    end
  end

  defp run_if_not_cancelled(%{provider_run_id: run_id} = context, phase_fun) do
    with :ok <- ensure_not_cancelled(run_id) do
      phase_fun.(context)
    end
  end

  defp finish_if_not_cancelled(%{provider_run_id: run_id} = context, manifest) do
    with :ok <- ensure_not_cancelled(run_id) do
      finish_compatibility_facade(context, manifest)
    end
  end

  defp ensure_not_cancelled(nil), do: :ok
  defp ensure_not_cancelled(""), do: :ok

  defp ensure_not_cancelled(run_id) when is_binary(run_id) do
    if Phases.RunState.cancelled?(run_id) do
      {:cancel, "provider run #{run_id} is cancelled"}
    else
      :ok
    end
  end

  defp fetch_phase(manifest_path, args) do
    context =
      %{manifest_path: manifest_path}
      |> maybe_put_context_id(:provider_source_id, args["provider_source_id"])
      |> maybe_put_context_id(:provider_run_id, args["provider_run_id"])

    case Phases.FetchSnapshot.run(context) do
      {:ok, context} -> {:ok, context}
      {:snooze, seconds} -> {:snooze, seconds}
      {:error, {code, message}} -> {:error, "sidecar fetch failed: #{code}: #{message}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_context_id(context, _key, value) when value in [nil, ""], do: context

  defp maybe_put_context_id(context, key, value) when is_binary(value),
    do: Map.put(context, key, value)

  # --- Step 1: Load manifest ---

  defp load_manifest(manifest_path) do
    manifest = ProviderManifest.load!(manifest_path)
    {:ok, manifest}
  rescue
    error -> {:error, "manifest load failed: #{Exception.message(error)}"}
  end

  # --- Step 2: Register provider in SourcePolicy ---

  defp register_provider(manifest_path) do
    SourcePolicy.load_provider_manifest(manifest_path)
  end

  def normalize_provider_records(records, manifest, client) do
    Hiraeth.Ingestion.ProviderRecordNormalizer.normalize(records, manifest, client)
  end

  @doc """
  Computes a content-derived SHA-256 checksum for a list of records.
  """
  def compute_file_checksum(records) do
    Hiraeth.Ingestion.ProviderRecordNormalizer.compute_file_checksum(records)
  end

  defp finish_compatibility_facade(phase_context, manifest) do
    records = phase_context.normalized_records
    run_id = phase_context.provider_run_id

    Phases.RunState.mark_phase(run_id, :provider_ingestion_worker, :succeeded, %{
      source_count: length(records),
      candidate_count:
        phase_context.candidate_count || length(phase_context.record_candidates || [])
    })

    {:ok,
     %{
       provider: manifest.provider,
       record_count: length(records),
       source_mode: manifest.source_mode
     }}
  end

  defp cache_covers_compatibility_phase(phase_context, manifest) do
    case CoverCandidateRun.cache_dataset_covers(phase_context.dataset, manifest, cover_pipeline()) do
      {:ok, _summary} ->
        {:ok, phase_context}

      {:error, reason} ->
        mark_provider_worker_failed(phase_context.provider_run_id, reason)
        {:error, reason}
    end
  rescue
    error ->
      reason = "cover cache failed: #{Exception.message(error)}"
      mark_provider_worker_failed(phase_context.provider_run_id, reason)
      {:error, reason}
  end

  defp mark_provider_worker_failed(run_id, reason) do
    Phases.RunState.mark_run_failed(run_id, :provider_ingestion_worker, reason)
  end

  # --- Injectable dependencies for testing ---

  defp cover_pipeline do
    Application.get_env(:hiraeth, :cover_pipeline, CoverPipeline)
  end
end
