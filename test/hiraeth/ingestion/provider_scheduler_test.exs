defmodule Hiraeth.Ingestion.ProviderSchedulerTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, ProviderScheduler}
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @tick_at ~U[2026-06-29 12:00:00Z]

  test "scheduler config is present" do
    # The devenv dev guard exports HIRAETH_SCHEDULED_INGEST=false, which
    # runtime.exs honors by dropping the scheduler cron entry entirely. The
    # full kill-switch matrix is pinned by Hiraeth.ObanConfigKillSwitchTest.
    if System.get_env("HIRAETH_SCHEDULED_INGEST", "true") == "false" do
      assert Application.fetch_env!(:hiraeth, Oban)
             |> Keyword.fetch!(:plugins)
             |> Enum.any?(&provider_scheduler_plugin?/1) == false
    else
      assert Application.fetch_env!(:hiraeth, Oban)
             |> Keyword.fetch!(:plugins)
             |> Enum.any?(&provider_scheduler_plugin?/1)
    end
  end

  test "scheduler creates queued provider runs and phase enqueue intent for enabled automatic sources" do
    source = create_source!("enabled-automatic", ingestion_mode: "manifest", enabled?: true)

    assert {:ok, %{created: [run], skipped: []}} =
             ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

    assert run.provider_source_id == source.id
    assert run.status == "queued"
    assert run.requested_by == "provider_scheduler"
    assert run.run_key == "scheduled:2026-06-29T12:00:00Z"
    assert run.provenance["scheduler"]["tick_at"] == "2026-06-29T12:00:00Z"
    assert run.provenance["retry"]["strategy"] == "exponential"
    assert run.provenance["phases"] == ["fetch_snapshot", "normalize_candidates", "review_ready"]

    assert [event] = events_for(run)
    assert event.event_kind == "phase_enqueue_intent"
    assert event.status == "queued"
    assert event.payload["phases"] == ["fetch_snapshot", "normalize_candidates", "review_ready"]
  end

  @tag :duplicate_tick
  test "duplicate schedule ticks adopt the queued run and skip re-dispatch on job conflict" do
    source = create_source!("duplicate-tick", ingestion_mode: "manifest", enabled?: true)

    opts = [now: @tick_at, provider_source_ids: [source.id]]

    assert {:ok, %{created: [run], dispatched: [dispatched], skipped: []}} =
             ProviderScheduler.schedule_tick(opts)

    assert dispatched.id == run.id

    # Still due: the queued scheduled run is adopted (not duplicated); the
    # pending job from the first tick conflicts, keeping the run queued.
    assert {:ok, %{created: [], adopted: [adopted], dispatched: [], skipped: []}} =
             ProviderScheduler.schedule_tick(opts)

    assert adopted.id == run.id

    assert [_single_active_run] = active_runs_for(source)
  end

  test "disabled and manual providers are skipped" do
    disabled = create_source!("disabled", ingestion_mode: "manifest", enabled?: false)
    manual = create_source!("manual", ingestion_mode: "manual", enabled?: true)

    assert {:ok, %{created: [], skipped: skipped}} =
             ProviderScheduler.schedule_tick(
               now: @tick_at,
               provider_source_ids: [disabled.id, manual.id]
             )

    assert Enum.find(skipped, &(&1.provider_source_id == disabled.id)).reason == :disabled
    assert Enum.find(skipped, &(&1.provider_source_id == manual.id)).reason == :manual_provider
    assert active_runs_for(disabled) == []
    assert active_runs_for(manual) == []
  end

  test "recent succeeded run suppresses the scheduled run (cadence gate)" do
    source = create_source!("stale-completed", ingestion_mode: "api", enabled?: true)

    _recent_run =
      create_run!(
        source,
        "scheduled:2026-06-29T11:00:00Z",
        "succeeded",
        DateTime.add(@tick_at, -1 * 3_600, :second)
      )

    assert {:ok, %{created: [], adopted: [], dispatched: [], skipped: [skip]}} =
             ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

    assert skip.provider_source_id == source.id
    assert skip.reason == :not_due
    assert active_runs_for(source) == []
  end

  test "cancelled run does not enqueue phases" do
    source = create_source!("cancelled", ingestion_mode: "scrape", enabled?: true)
    run = create_run!(source, "scheduled:2026-06-29T12:00:00Z", "cancelled")

    assert {:ok, :cancelled} = ProviderScheduler.enqueue_phase_intent(run.id)

    assert events_for(run) == []
  end

  defp provider_scheduler_plugin?({Oban.Plugins.Cron, opts}) do
    opts
    |> Keyword.get(:crontab, [])
    |> Enum.any?(fn
      {_cron, Hiraeth.Oban.ProviderSchedulerWorker} -> true
      {_cron, Hiraeth.Oban.ProviderSchedulerWorker, _opts} -> true
      _other -> false
    end)
  end

  defp provider_scheduler_plugin?(_plugin), do: false

  defp create_source!(suffix, attrs) do
    IngestionFixtures.create_provider_source!(suffix)
    |> Ash.Changeset.for_update(:update, Map.new(attrs))
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_run!(source, run_key, status, finished_at \\ nil) do
    attrs = %{
      provider_source_id: source.id,
      status: status,
      requested_by: "provider_scheduler",
      run_key: run_key,
      provenance: %{}
    }

    attrs = if is_nil(finished_at), do: attrs, else: Map.put(attrs, :finished_at, finished_at)

    ProviderRun
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp active_runs_for(source) do
    ProviderRun
    |> Ash.Query.filter(provider_source_id == ^source.id and status in ["queued", "running"])
    |> Ash.read!(authorize?: false)
  end

  defp events_for(run) do
    IngestionEvent
    |> Ash.Query.filter(provider_run_id == ^run.id)
    |> Ash.read!(authorize?: false)
  end
end
