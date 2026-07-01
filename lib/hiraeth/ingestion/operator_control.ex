defmodule Hiraeth.Ingestion.OperatorControl do
  @moduledoc false

  alias Hiraeth.Ingestion.{OperatorJSON, ProviderRun}
  alias Hiraeth.Ingestion.Phases
  alias Hiraeth.Ingestion.Phases.RunState

  import Ecto.Query

  def cancel_run(run_id, opts) do
    with {:ok, run} <- get_provider_run(run_id),
         :ok <- ensure_cancellable(run),
         {job_count, cancelled_job_count} <- cancel_correlated_jobs(run.id),
         {:ok, cancelled} <- update_run_cancelled(run) do
      payload = %{
        action: "cancel",
        status: "cancelled",
        run_id: cancelled.id,
        previous_status: run.status,
        correlated_oban_jobs: job_count,
        cancelled_oban_jobs: cancelled_job_count
      }

      if json?(opts) do
        OperatorJSON.print(payload)
      else
        Mix.shell().info("Provider run #{run.id} cancelled.")
        Mix.shell().info("cancelled_oban_jobs=#{cancelled_job_count}")
      end

      :ok
    end
  end

  defp cancel_correlated_jobs(run_id) do
    jobs = correlated_jobs(run_id)

    cancellable_jobs =
      Enum.reject(jobs, &(&1.state in ["completed", "discarded", "cancelled"]))

    cancelled_count = Enum.count(cancellable_jobs, &cancelled_job?/1)

    {length(jobs), cancelled_count}
  end

  defp correlated_jobs(run_id) do
    Oban.Job
    |> where([job], fragment("?->>? = ?", job.args, "provider_run_id", ^run_id))
    |> Hiraeth.Repo.all()
  end

  defp cancelled_job?(job) do
    Oban.cancel_job(job)

    case Hiraeth.Repo.get(Oban.Job, job.id) do
      %{state: "cancelled"} -> true
      _job -> false
    end
  end

  def replay_run(run_id, opts) do
    with {:ok, run} <- get_provider_run(run_id),
         {:ok, replayed} <- Phases.ReplaySnapshot.run(%{provider_run_id: run.id}) do
      payload = %{
        action: "replay",
        status: "succeeded",
        run_id: run.id,
        replay_record_count: length(replayed.replay_records),
        destructive_apply: false
      }

      if json?(opts) do
        OperatorJSON.print(payload)
      else
        Mix.shell().info("Replay prepared for provider run #{run.id}.")
        Mix.shell().info("replay_records=#{length(replayed.replay_records)}")
      end

      :ok
    else
      {:error, {code, message}} -> {:error, "replay failed: #{code}: #{message}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_provider_run(run_id) do
    case Ash.get(ProviderRun, run_id, authorize?: false) do
      {:ok, %ProviderRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, "Provider run not found: #{run_id}"}
      {:error, _error} -> {:error, "Provider run not found: #{run_id}"}
    end
  rescue
    _error -> {:error, "Provider run not found: #{run_id}"}
  end

  defp ensure_cancellable(%ProviderRun{status: status}) when status in ["queued", "running"] do
    :ok
  end

  defp ensure_cancellable(%ProviderRun{status: status}) do
    {:error, "Provider run cannot be cancelled from status #{status}"}
  end

  defp update_run_cancelled(run) do
    run
    |> Ash.Changeset.for_update(:cancel, %{finished_at: DateTime.utc_now(:second)})
    |> Ash.update(actor: RunState.catalog_writer())
  rescue
    error -> {:error, "cancel failed: #{Exception.message(error)}"}
  end

  defp json?(opts), do: Keyword.get(opts, :json, false)
end
