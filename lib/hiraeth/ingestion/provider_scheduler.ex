defmodule Hiraeth.Ingestion.ProviderScheduler do
  @moduledoc """
  Plans and dispatches provider ingestion runs from enabled provider sources.

  The scheduler is cadence-gated: for every enabled non-manual source with no
  active run, a run is planned only when no succeeded run exists since
  `now - cadence_hours`. Planned runs are dispatched to `ProviderIngestionWorker`
  via `Oban.insert/1` (conflict-safe: a duplicate insert returns the pending job
  instead of raising), at most `@dispatch_cap` per tick, oldest-last-succeeded
  first, with `"scheduled" => true` args. A stale queued scheduled run for a due
  provider is adopted instead of duplicated.

  The scheduler intentionally stops at run planning and dispatch. Later
  safeguards own destructive catalog application.
  """

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, ProviderSource, Telemetry}
  alias Hiraeth.Oban.ProviderIngestionWorker

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
  @dispatch_cap 2
  @scheduler_requested_by "provider_scheduler"

  def schedule_tick(opts \\ []) do
    started_at = System.monotonic_time()
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    provider_source_ids = Keyword.get(opts, :provider_source_ids)
    tick_at = DateTime.to_iso8601(now)

    sources =
      ProviderSource
      |> Ash.read!(authorize?: false)
      |> filter_provider_source_ids(provider_source_ids)
      |> Enum.sort_by(& &1.stable_source_key)

    last_succeeded = last_succeeded_at_by_source(sources)
    {skipped, due_candidates} = classify_sources(sources, now, last_succeeded)

    Telemetry.scheduler_dispatch_start(%{tick_at: tick_at})
    dispatch_started_at = System.monotonic_time()

    {taken, deferred} =
      due_candidates
      |> sort_by_oldest_last_succeeded(last_succeeded)
      |> Enum.split(@dispatch_cap)

    deferred_skips = Enum.map(deferred, &skip_due_candidate/1)

    {dispatched, skipped} = dispatch_taken(taken, now, skipped ++ deferred_skips)

    summary = %{
      created: collect_created(dispatched),
      adopted: collect_adopted(dispatched),
      dispatched: collect_dispatched(dispatched),
      skipped: skipped
    }

    Telemetry.scheduler_dispatch_stop(
      %{
        duration: native_duration(dispatch_started_at),
        dispatched_count: length(summary.dispatched)
      },
      %{tick_at: tick_at, dispatched_count: length(summary.dispatched)}
    )

    Telemetry.scheduler_tick(summary, %{duration: native_duration(started_at)}, %{
      tick_at: tick_at
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

  # --- Cadence-gated planning ---

  defp classify_sources(sources, now, last_succeeded) do
    Enum.reduce(sources, {[], []}, fn source, {skipped, due} ->
      cond do
        not source.enabled? ->
          {[skip(source, :disabled) | skipped], due}

        manual_provider?(source) ->
          {[skip(source, :manual_provider) | skipped], due}

        true ->
          classify_source(source, now, last_succeeded, skipped, due)
      end
    end)
    |> then(fn {skipped, due} -> {Enum.reverse(skipped), Enum.reverse(due)} end)
  end

  defp classify_source(source, now, last_succeeded, skipped, due) do
    case active_run_for(source) do
      %ProviderRun{status: "queued", requested_by: @scheduler_requested_by} = run ->
        if due?(source, now, last_succeeded) do
          {skipped, [{:adopt, source, run} | due]}
        else
          {[skip(source, :not_due) | skipped], due}
        end

      %ProviderRun{} ->
        {[skip(source, :active_run_exists) | skipped], due}

      nil ->
        if due?(source, now, last_succeeded) do
          {skipped, [{:create, source} | due]}
        else
          {[skip(source, :not_due) | skipped], due}
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

  defp last_succeeded_at_by_source(sources) do
    source_ids = Enum.map(sources, & &1.id)

    ProviderRun
    |> Ash.Query.filter(status == "succeeded" and provider_source_id in ^source_ids)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(%{}, fn run, acc ->
      Map.update(acc, run.provider_source_id, run.finished_at, fn existing ->
        newest_finished(existing, run.finished_at)
      end)
    end)
  end

  defp newest_finished(nil, newer), do: newer
  defp newest_finished(current, nil), do: current

  defp newest_finished(current, newer) do
    case DateTime.compare(newer, current) do
      :gt -> newer
      _other -> current
    end
  end

  defp due?(source, now, last_succeeded) do
    case Map.get(last_succeeded, source.id) do
      nil ->
        true

      finished_at ->
        case DateTime.compare(DateTime.add(finished_at, source.cadence_hours, :hour), now) do
          :gt -> false
          _other -> true
        end
    end
  end

  defp sort_by_oldest_last_succeeded(candidates, last_succeeded) do
    Enum.sort_by(candidates, fn
      {:create, source} -> last_succeeded_sort_key(Map.get(last_succeeded, source.id))
      {:adopt, source, _run} -> last_succeeded_sort_key(Map.get(last_succeeded, source.id))
    end)
  end

  defp last_succeeded_sort_key(nil), do: {0, nil}
  defp last_succeeded_sort_key(datetime), do: {1, datetime}

  defp skip_due_candidate({:create, source}), do: skip(source, :dispatch_cap_deferred)
  defp skip_due_candidate({:adopt, source, _run}), do: skip(source, :dispatch_cap_deferred)

  # --- Run creation, adoption, and dispatch ---

  defp dispatch_taken(taken, now, skipped) do
    Enum.reduce(taken, {[], skipped}, fn
      {:create, source}, {dispatched, skips} ->
        case create_scheduled_run(source, now) do
          {:created, run} ->
            dispatch_outcome(run, source, now, :created, dispatched, skips)

          {:skipped, skip} ->
            {dispatched, [skip | skips]}
        end

      {:adopt, source, run}, {dispatched, skips} ->
        dispatch_outcome(run, source, now, :adopted, dispatched, skips)
    end)
    |> then(fn {dispatched, skips} -> {Enum.reverse(dispatched), Enum.reverse(skips)} end)
  end

  defp dispatch_outcome(run, source, now, kind, dispatched, skips) do
    case dispatch_run(run, source, now) do
      :dispatched -> {[{kind, run, true} | dispatched], skips}
      :conflict -> {[{kind, run, false} | dispatched], skips}
    end
  end

  defp dispatch_run(run, source, now) do
    args = %{
      "scheduled" => true,
      provider: source.stable_source_key,
      manifest_path: source.manifest_uri,
      provider_source_id: source.id,
      provider_run_id: run.id
    }

    case Oban.insert(ProviderIngestionWorker.new(args)) do
      {:ok, %Oban.Job{conflict?: true}} ->
        write_dispatch_skipped!(run, source, now)
        :conflict

      {:ok, %Oban.Job{}} ->
        create_phase_enqueue_intent!(run, now)
        :dispatched

      {:error, _reason} ->
        write_dispatch_skipped!(run, source, now)
        :conflict
    end
  end

  defp create_scheduled_run(source, now) do
    run =
      ProviderRun
      |> Ash.Changeset.for_create(:create, %{
        provider_source_id: source.id,
        status: "queued",
        requested_by: @scheduler_requested_by,
        run_key: run_key(now),
        provenance: provenance(source, now)
      })
      |> Ash.create!(actor: @catalog_writer)

    {:created, run}
  rescue
    error in Ash.Error.Invalid ->
      if Exception.message(error) =~ "has already been taken" do
        {:skipped, skip(source, :active_run_exists)}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp write_dispatch_skipped!(run, source, now) do
    IngestionEvent
    |> Ash.Changeset.for_create(:create, %{
      provider_run_id: run.id,
      provider_source_id: run.provider_source_id,
      event_kind: "dispatch_skipped_job_pending",
      status: "warning",
      message: "Scheduled dispatch skipped: a provider job is already pending.",
      payload: %{"provider" => source.stable_source_key},
      occurred_at: now
    })
    |> Ash.create!(actor: @catalog_writer)
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

  defp collect_created(dispatched) do
    dispatched
    |> Enum.filter(&(&1 |> elem(0) == :created))
    |> Enum.map(&elem(&1, 1))
  end

  defp collect_adopted(dispatched) do
    dispatched
    |> Enum.filter(&(&1 |> elem(0) == :adopted))
    |> Enum.map(&elem(&1, 1))
  end

  defp collect_dispatched(dispatched) do
    dispatched
    |> Enum.filter(&(elem(&1, 2) == true))
    |> Enum.map(&elem(&1, 1))
  end
end
