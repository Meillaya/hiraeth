defmodule Hiraeth.Ingestion.OperatorCLI do
  @moduledoc "Operator-facing implementation for `mix hiraeth.ingest`."

  alias Hiraeth.Ingestion.{OperatorControl, OperatorDryRun, OperatorJSON, OperatorManifest}
  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.Ingestion.SidecarClient
  alias Hiraeth.Oban.ProviderIngestionWorker

  import Ecto.Query

  require Ash.Query

  @poll_interval 2_000
  @max_timeout_ms :timer.minutes(30)

  @doc false
  def run_args(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          provider: :string,
          manifest: :string,
          dry_run: :boolean,
          wait: :boolean,
          json: :boolean,
          replay: :string,
          cancel: :string
        ]
      )

    cond do
      run_id = Keyword.get(opts, :cancel) ->
        cancel_run(run_id, opts)

      run_id = Keyword.get(opts, :replay) ->
        replay_run(run_id, opts)

      true ->
        provider = Keyword.get(opts, :provider)

        if is_nil(provider) or String.trim(provider) == "" do
          {:error, usage()}
        else
          manifest_path = Keyword.get(opts, :manifest, OperatorManifest.default_path(provider))

          if Keyword.get(opts, :dry_run) do
            run_dry_run(provider, manifest_path, opts)
          else
            run_ingestion(provider, manifest_path, opts)
          end
        end
    end
  end

  defp usage do
    "Usage: mix hiraeth.ingest --provider <slug> [--manifest <path>] [--dry-run] [--json] [--wait] [--replay RUN_ID] [--cancel RUN_ID]"
  end

  defp run_ingestion(provider, manifest_path, opts) do
    with {:ok, manifest} <- OperatorManifest.load(manifest_path),
         :ok <- OperatorManifest.ensure_provider_matches(provider, manifest),
         :ok <- check_sidecar_health(),
         {:ok, source, run} <- create_operator_run(manifest, manifest_path),
         {:ok, job} <- enqueue_job(provider, manifest_path, source, run, opts),
         :ok <- maybe_print_started(provider, run, job, opts),
         :ok <- maybe_poll_and_report(job.id, provider, run.id, opts) do
      :ok
    end
  end

  defp check_sidecar_health do
    case sidecar_client().health() do
      {:ok, %{status: "ok"}} ->
        :ok

      _error ->
        {:error,
         "Scrapling sidecar is not running. Start it with: docker compose up -d scrapling-sidecar"}
    end
  end

  defp sidecar_client do
    Application.get_env(:hiraeth, :sidecar_client, SidecarClient)
  end

  defp create_operator_run(manifest, manifest_path) do
    {source, run} =
      RunState.ensure_source_and_run!(manifest,
        requested_by: "mix hiraeth.ingest",
        run_key: operator_run_key(manifest.provider),
        provenance: %{
          manifest_path: manifest_path,
          operator_cli: true,
          destructive_apply: false
        }
      )

    {:ok, source, run}
  rescue
    error -> {:error, "provider run creation failed: #{Exception.message(error)}"}
  end

  defp enqueue_job(provider, manifest_path, source, run, _opts) do
    args = %{
      provider: provider,
      manifest_path: manifest_path,
      provider_source_id: source.id,
      provider_run_id: run.id
    }

    job =
      ProviderIngestionWorker.new(args)
      |> Oban.insert!()

    {:ok, job}
  rescue
    error -> {:error, "ingestion enqueue failed: #{Exception.message(error)}"}
  end

  defp maybe_print_started(provider, run, job, opts) do
    if json?(opts) do
      OperatorJSON.print(%{
        action: "ingest",
        status: "started",
        provider: provider,
        run_id: run.id,
        oban_job_id: job.id,
        wait: wait?(opts)
      })
    else
      Mix.shell().info("Ingestion started for provider: #{provider}")
      Mix.shell().info("Provider run ID: #{run.id}")
      Mix.shell().info("Job ID: #{job.id}")
    end

    :ok
  end

  defp maybe_poll_and_report(job_id, provider, run_id, opts) do
    # Preserve existing operator behavior: wait for completion unless callers opt
    # into machine-readable JSON, where the start envelope is the stable output.
    if json?(opts) and not wait?(opts) do
      :ok
    else
      poll_and_report(job_id, provider, run_id, opts)
    end
  end

  defp poll_and_report(job_id, provider, run_id, opts) do
    deadline = System.monotonic_time(:millisecond) + @max_timeout_ms

    case poll_loop(job_id, deadline) do
      {:ok, _job} ->
        if json?(opts) do
          OperatorJSON.print(run_summary_payload(provider, run_id, "completed"))
        else
          print_summary(provider, run_id)
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_loop(job_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now > deadline do
      {:error, "Ingestion timed out after #{div(@max_timeout_ms, 1000)} seconds"}
    else
      case Hiraeth.Repo.get(Oban.Job, job_id) do
        nil ->
          {:error, "Job #{job_id} not found"}

        %{state: "completed"} = job ->
          {:ok, job}

        %{state: "discarded"} = job ->
          {:error, format_discarded_error(job)}

        %{state: "cancelled"} ->
          {:error, "Job #{job_id} was cancelled"}

        _other ->
          Process.sleep(@poll_interval)
          poll_loop(job_id, deadline)
      end
    end
  end

  defp format_discarded_error(%{errors: errors}) when is_list(errors) do
    last_error = List.last(errors) || %{}
    error_msg = last_error["error"] || last_error[:error] || "unknown error"
    "Ingestion failed: #{error_msg}"
  end

  defp format_discarded_error(_job) do
    "Ingestion failed: unknown error"
  end

  defp print_summary(provider, run_id) do
    Mix.shell().info("Ingestion completed for provider: #{provider}")
    Mix.shell().info("provider_run_id=#{run_id}")

    source_count = count_source_records(provider)
    edition_count = count_editions(provider)
    cover_count = count_covers(provider)

    Mix.shell().info("source_records=#{source_count}")
    Mix.shell().info("editions=#{edition_count}")
    Mix.shell().info("covers=#{cover_count}")
  end

  defp run_dry_run(provider, manifest_path, opts),
    do: OperatorDryRun.run(provider, manifest_path, opts)

  defp cancel_run(run_id, opts), do: OperatorControl.cancel_run(run_id, opts)

  defp replay_run(run_id, opts), do: OperatorControl.replay_run(run_id, opts)

  defp run_summary_payload(provider, run_id, status) do
    %{
      action: "ingest",
      status: status,
      provider: provider,
      run_id: run_id,
      source_records: count_source_records(provider),
      editions: count_editions(provider),
      covers: count_covers(provider)
    }
  end

  defp operator_run_key(provider) do
    "operator:#{provider}:#{System.system_time(:microsecond)}:#{System.unique_integer([:positive])}"
  end

  defp json?(opts), do: Keyword.get(opts, :json, false)
  defp wait?(opts), do: Keyword.get(opts, :wait, false)

  defp count_source_records(provider) do
    Hiraeth.Sources.SourceRecord
    |> Ash.Query.filter(provider: provider)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp count_editions(provider) do
    import Ecto.Query

    count =
      from(e in Hiraeth.Catalog.Edition,
        join: sr in Hiraeth.Sources.SourceRecord,
        on: sr.edition_id == e.id,
        where: sr.provider == ^provider,
        select: count(e.id, :distinct)
      )
      |> Hiraeth.Repo.one()

    count || 0
  end

  defp count_covers(provider) do
    Hiraeth.Covers.CoverAsset
    |> Ash.Query.filter(provider: provider)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
