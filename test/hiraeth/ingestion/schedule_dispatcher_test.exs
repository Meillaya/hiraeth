defmodule Hiraeth.Ingestion.ScheduleDispatcherTest do
  @moduledoc """
  Cadence-gated schedule dispatcher contract: due-run planning, stale-run
  adoption, per-tick dispatch cap ordering, and Oban conflict semantics.
  """

  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{IngestionEvent, ProviderRun, ProviderScheduler}
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.TestSupport.IngestionFixtures

  import Ecto.Query

  require Ash.Query

  @tick_at ~U[2026-08-05 12:00:00Z]

  describe "cadence-gated planning" do
    test "due source gets a queued scheduled run and one dispatched job" do
      source = create_source!("due-dispatch")
      _stale = create_succeeded_run!(source, "due-dispatch-stale", hours_before(25))

      assert {:ok, summary} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert [run] = summary.created
      assert [dispatched] = summary.dispatched
      assert dispatched.id == run.id
      assert run.provider_source_id == source.id
      assert run.status == "queued"
      assert run.requested_by == "provider_scheduler"
      assert run.run_key == "scheduled:2026-08-05T12:00:00Z"
      assert run.provenance["scheduler"]["tick_at"] == "2026-08-05T12:00:00Z"
      assert run.provenance["destructive_apply"] == false

      assert [job] = ingestion_jobs()
      assert job.state == "available"
      assert job.args["provider"] == source.stable_source_key
      assert job.args["manifest_path"] == source.manifest_uri
      assert job.args["provider_source_id"] == source.id
      assert job.args["provider_run_id"] == run.id
      assert job.args["scheduled"] == true

      assert [event] = events_for(run)
      assert event.event_kind == "phase_enqueue_intent"
      assert event.status == "queued"
      assert event.payload["phases"] == ["fetch_snapshot", "normalize_candidates", "review_ready"]
      assert event.payload["destructive_apply"] == false
    end

    test "source with a recent succeeded run is not due: no run created, no job enqueued" do
      source = create_source!("not-due")
      _recent = create_succeeded_run!(source, "not-due-recent", hours_before(1))

      assert {:ok, %{created: [], adopted: [], dispatched: [], skipped: skipped}} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert [%{reason: :not_due}] =
               Enum.filter(skipped, &(&1.provider_source_id == source.id))

      assert ingestion_jobs() == []
      assert active_runs_for(source) == []
    end

    test "cadence_hours is honored per source" do
      source =
        create_source!("short-cadence")
        |> update_source!(cadence_hours: 6)

      _recent = create_succeeded_run!(source, "short-cadence-recent", hours_before(7))

      assert {:ok, %{created: [run], dispatched: [_job_run]}} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert run.provider_source_id == source.id
    end

    test "source with an active running run is skipped" do
      source = create_source!("running-elsewhere")
      _running = create_run_with_status!(source, "running-elsewhere-run", "running")

      assert {:ok, %{created: [], dispatched: [], skipped: skipped}} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert [%{reason: :active_run_exists}] =
               Enum.filter(skipped, &(&1.provider_source_id == source.id))

      assert ingestion_jobs() == []
    end

    test "source with a queued operator run is skipped" do
      source = create_source!("operator-queued")
      _operator_run = create_run_with_status!(source, "operator-queued-run", "queued")

      assert {:ok, %{created: [], dispatched: [], skipped: skipped}} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert [%{reason: :active_run_exists}] =
               Enum.filter(skipped, &(&1.provider_source_id == source.id))

      assert ingestion_jobs() == []
    end

    test "disabled and manual providers are skipped without jobs" do
      disabled = create_source!("dispatch-disabled") |> update_source!(enabled?: false)
      manual = create_source!("dispatch-manual") |> update_source!(ingestion_mode: "manual")

      assert {:ok, %{created: [], dispatched: [], skipped: skipped}} =
               ProviderScheduler.schedule_tick(
                 now: @tick_at,
                 provider_source_ids: [disabled.id, manual.id]
               )

      assert Enum.find(skipped, &(&1.provider_source_id == disabled.id)).reason == :disabled
      assert Enum.find(skipped, &(&1.provider_source_id == manual.id)).reason == :manual_provider
      assert ingestion_jobs() == []
    end
  end

  describe "stale queued run adoption" do
    test "an existing queued scheduled run is adopted, not duplicated" do
      source = create_source!("adopt-stale")
      stale = create_queued_scheduled_run!(source, "scheduled:2026-08-04T09:00:00Z")

      assert {:ok, summary} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert summary.created == []
      assert [adopted] = summary.adopted
      assert adopted.id == stale.id
      assert [dispatched] = summary.dispatched
      assert dispatched.id == stale.id

      assert [job] = ingestion_jobs()
      assert job.args["provider_run_id"] == stale.id
      assert job.args["scheduled"] == true

      assert [run] = active_runs_for(source)
      assert run.id == stale.id
      assert run.status == "queued"
    end
  end

  describe "per-tick dispatch cap" do
    test "dispatches at most 2 providers per tick, oldest last-succeeded first" do
      source_a = create_source!("cap-a")
      source_b = create_source!("cap-b")
      source_c = create_source!("cap-c")
      create_succeeded_run!(source_a, "cap-a-old", hours_before(50))
      create_succeeded_run!(source_b, "cap-b-mid", hours_before(30))
      create_succeeded_run!(source_c, "cap-c-new", hours_before(26))

      ids = [source_c.id, source_a.id, source_b.id]

      assert {:ok, summary} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: ids)

      assert length(summary.dispatched) == 2
      assert length(summary.created) == 2

      assert Enum.map(summary.dispatched, & &1.provider_source_id) == [
               source_a.id,
               source_b.id
             ]

      assert length(ingestion_jobs()) == 2

      skip = Enum.find(summary.skipped, &(&1.provider_source_id == source_c.id))
      assert skip.reason == :dispatch_cap_deferred
      assert active_runs_for(source_c) == []
    end

    test "sources that never succeeded dispatch before stale successes" do
      never = create_source!("cap-never")
      stale = create_source!("cap-stale-success")
      create_succeeded_run!(stale, "cap-stale-success-run", hours_before(40))

      assert {:ok, summary} =
               ProviderScheduler.schedule_tick(
                 now: @tick_at,
                 provider_source_ids: [stale.id, never.id]
               )

      assert Enum.map(summary.dispatched, & &1.provider_source_id) == [never.id, stale.id]
    end
  end

  describe "conflict semantics" do
    test "a pending job for the provider keeps the run queued and writes dispatch_skipped_job_pending" do
      source = create_source!("conflict-pending")

      assert {:ok, _manual_job} =
               Oban.insert(
                 ProviderIngestionWorker.new(%{
                   provider: source.stable_source_key,
                   manifest_path: source.manifest_uri
                 })
               )

      assert {:ok, summary} =
               ProviderScheduler.schedule_tick(now: @tick_at, provider_source_ids: [source.id])

      assert [run] = summary.created
      assert summary.dispatched == []
      assert run.status == "queued"

      # The pre-existing manual job stays the only job; no duplicate enqueue.
      assert [job] = ingestion_jobs()
      assert job.args["provider_run_id"] in [nil]

      assert [event] = events_for(run)
      assert event.event_kind == "dispatch_skipped_job_pending"
      assert event.status == "warning"
      assert event.payload["provider"] == source.stable_source_key

      assert [still_queued] = active_runs_for(source)
      assert still_queued.id == run.id
    end
  end

  # --- Helpers ---

  defp create_source!(suffix), do: IngestionFixtures.create_provider_source!(suffix)

  defp update_source!(source, attrs) do
    source
    |> Ash.Changeset.for_update(:update, Map.new(attrs))
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_succeeded_run!(source, suffix, finished_at) do
    source
    |> IngestionFixtures.create_provider_run!(suffix)
    |> Ash.Changeset.for_update(:mark_succeeded, %{finished_at: finished_at})
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp create_run_with_status!(source, suffix, status) do
    run = IngestionFixtures.create_provider_run!(source, suffix)

    if status == "queued" do
      run
    else
      run
      |> Ash.Changeset.for_update(:record_progress, %{status: status})
      |> Ash.update!(actor: IngestionFixtures.catalog_writer())
    end
  end

  defp create_queued_scheduled_run!(source, run_key) do
    ProviderRun
    |> Ash.Changeset.for_create(:create, %{
      provider_source_id: source.id,
      status: "queued",
      requested_by: "provider_scheduler",
      run_key: run_key,
      provenance: %{}
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp hours_before(hours) do
    DateTime.add(@tick_at, -hours * 3_600, :second)
  end

  defp ingestion_jobs do
    Hiraeth.Repo.all(from(job in Oban.Job, where: job.queue == "ingestion"))
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
