defmodule Hiraeth.Oban.SourceSnapshotReplayWorker do
  @moduledoc "Admin-enqueued worker for retained source snapshot replay preparation."

  use Oban.Worker, queue: :audit

  alias Hiraeth.Ingestion.Phases.ReplaySnapshot

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_run_id" => run_id}}) when is_binary(run_id) do
    case ReplaySnapshot.run(%{provider_run_id: run_id}) do
      {:ok, context} -> {:ok, %{replay_record_count: length(context.replay_records)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:error, :missing_provider_run_id}
end
