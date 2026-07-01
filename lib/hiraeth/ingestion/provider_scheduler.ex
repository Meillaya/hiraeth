defmodule Hiraeth.Ingestion.ProviderScheduler do
  @moduledoc """
  Plans provider ingestion runs from enabled provider sources.

  The scheduler intentionally stops at run planning and phase-enqueue intent.
  Later safeguards own destructive catalog application.
  """

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, ProviderSource, Telemetry}

  require Ash.Query

  @catalog_writer %{id: "provider-scheduler", catalog_write?: true}
  @active_statuses ["queued", "running"]
  @manual_modes ["manual"]
  @phases ["fetch_snapshot", "normalize_candidates", "review_ready"]
  @retry_metadata %{
    "strategy" => "exponential",
    "max_attempts" => 5,
    "base_backoff_seconds" => 60,
    "max_backoff_seconds" => 3600
  }

  def schedule_tick(opts \\ []) do
    started_at = System.monotonic_time()
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    provider_source_ids = Keyword.get(opts, :provider_source_ids)

    results =
      ProviderSource
      |> Ash.read!(authorize?: false)
      |> filter_provider_source_ids(provider_source_ids)
      |> Enum.sort_by(& &1.stable_source_key)
      |> Enum.map(&plan_source(&1, now))

    summary = %{
      created: collect_created(results),
      skipped: collect_skipped(results)
    }

    Telemetry.scheduler_tick(summary, %{duration: native_duration(started_at)}, %{
      tick_at: DateTime.to_iso8601(now)
    })

    {:ok, summary}
  end

  defp native_duration(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp filter_provider_source_ids(sources, nil), do: sources

  defp filter_provider_source_ids(sources, provider_source_ids) do
    provider_source_ids = MapSet.new(provider_source_ids)
    Enum.filter(sources, &MapSet.member?(provider_source_ids, &1.id))
  end

  def enqueue_phase_intent(run_id, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    run = Ash.get!(ProviderRun, run_id, authorize?: false)

    case run.status do
      "cancelled" ->
        {:ok, :cancelled}

      status when status in @active_statuses ->
        create_phase_enqueue_intent!(run, now)
        {:ok, :enqueued}

      status ->
        {:ok, {:skipped, String.to_atom(status)}}
    end
  end

  defp plan_source(%ProviderSource{enabled?: false} = source, _now) do
    {:skipped, skip(source, :disabled)}
  end

  defp plan_source(%ProviderSource{} = source, now) do
    if manual_provider?(source) do
      {:skipped, skip(source, :manual_provider)}
    else
      case active_run_for(source) do
        nil -> create_scheduled_run(source, now)
        _run -> {:skipped, skip(source, :active_run_exists)}
      end
    end
  end

  defp manual_provider?(source) do
    source.source_kind in @manual_modes or source.ingestion_mode in @manual_modes
  end

  defp active_run_for(source) do
    ProviderRun
    |> Ash.Query.filter(provider_source_id == ^source.id and status in @active_statuses)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp create_scheduled_run(source, now) do
    run =
      ProviderRun
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        status: "queued",
        requested_by: "provider_scheduler",
        run_key: run_key(now),
        provenance: provenance(source, now)
      })
      |> Ash.create!(actor: @catalog_writer)

    {:ok, :enqueued} = enqueue_phase_intent(run.id, now: now)
    {:created, run}
  rescue
    error in Ash.Error.Invalid ->
      if Exception.message(error) =~ "has already been taken" do
        {:skipped, skip(source, :active_run_exists)}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp create_phase_enqueue_intent!(run, now) do
    IngestionEvent
    |> Ash.Changeset.for_create(:create, %{
      provider_run_id: run.id,
      provider_source_id: run.provider_source_id,
      event_kind: "phase_enqueue_intent",
      status: "queued",
      message: "Provider run phases planned for enqueue.",
      payload: %{
        phases: @phases,
        retry: @retry_metadata,
        destructive_apply: false
      },
      occurred_at: now
    })
    |> Ash.create!(actor: @catalog_writer)
  end

  defp provenance(source, now) do
    %{
      scheduler: %{
        tick_at: DateTime.to_iso8601(now),
        source_key: source.stable_source_key
      },
      phase_enqueue_intent: true,
      destructive_apply: false,
      phases: @phases,
      retry: @retry_metadata,
      backoff: @retry_metadata
    }
  end

  defp run_key(now), do: "scheduled:#{DateTime.to_iso8601(now)}"

  defp skip(source, reason) do
    %{
      provider_source_id: source.id,
      stable_source_key: source.stable_source_key,
      reason: reason
    }
  end

  defp collect_created(results) do
    results
    |> Enum.filter(&match?({:created, _run}, &1))
    |> Enum.map(fn {:created, run} -> run end)
  end

  defp collect_skipped(results) do
    results
    |> Enum.filter(&match?({:skipped, _skip}, &1))
    |> Enum.map(fn {:skipped, skip} -> skip end)
  end
end
