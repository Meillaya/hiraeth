defmodule Hiraeth.Oban.ProviderSchedulerWorker do
  @moduledoc """
  Oban entrypoint for scheduled provider-run planning.
  """

  use Oban.Worker,
    queue: :ingestion,
    unique: [
      keys: [:tick_at],
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      period: 60
    ]

  alias Hiraeth.Ingestion.{ProviderScheduler, Telemetry}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tick_at" => tick_at} = args, inserted_at: inserted_at}) do
    Telemetry.queue_latency(:provider_scheduler_worker, inserted_at)

    with {:ok, now, _offset} <- DateTime.from_iso8601(tick_at),
         {:ok, summary} <-
           ProviderScheduler.schedule_tick(
             now: now,
             provider_source_ids: provider_source_ids(args)
           ) do
      {:ok, summary}
    end
  end

  def perform(%Oban.Job{args: args, inserted_at: inserted_at}) do
    Telemetry.queue_latency(:provider_scheduler_worker, inserted_at)
    ProviderScheduler.schedule_tick(provider_source_ids: provider_source_ids(args || %{}))
  end

  defp provider_source_ids(%{"provider_source_id" => provider_source_id})
       when is_binary(provider_source_id) and provider_source_id != "" do
    [provider_source_id]
  end

  defp provider_source_ids(%{"provider_source_ids" => provider_source_ids})
       when is_list(provider_source_ids) do
    Enum.filter(provider_source_ids, &(is_binary(&1) and &1 != ""))
  end

  defp provider_source_ids(_args), do: nil
end
