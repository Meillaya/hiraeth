defmodule Hiraeth.Ingestion.MixTaskControlTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.ProviderRun
  alias Hiraeth.Ingestion.Phases.RunState
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.TestSupport.IngestionFixtures
  alias Hiraeth.TestSupport.MixTaskMocks.{MockCoverPipeline, MockImporter, MockSidecarClient}

  import Ecto.Query

  require Ash.Query

  @valid_manifest Path.join([
                    File.cwd!(),
                    "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                  ])

  setup do
    Application.put_env(:hiraeth, :sidecar_client, MockSidecarClient)
    Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
    Application.put_env(:hiraeth, :importer, MockImporter)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
    end)

    :ok
  end

  describe "wait json" do
    test "--wait --json prints started and completion envelopes" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          task =
            Task.async(fn ->
              Mix.Tasks.Hiraeth.Ingest.do_run([
                "--provider",
                "test_publisher_api",
                "--manifest",
                @valid_manifest,
                "--wait",
                "--json"
              ])
            end)

          wait_for_ingestion_job()
          Oban.drain_queue(queue: :ingestion, with_safety: false)
          assert :ok = Task.await(task, 60_000)
        end)

      assert [started, completed] = decode_json_lines(output)
      assert started["action"] == "ingest"
      assert started["status"] == "started"
      assert started["wait"] == true
      assert is_integer(started["oban_job_id"])
      assert completed["status"] == "completed"
      assert completed["provider"] == "test_publisher_api"
      assert completed["run_id"] == started["run_id"]
    end
  end

  describe "operator control commands" do
    test "cancel marks an active provider run and correlated Oban job cancelled" do
      source = IngestionFixtures.create_provider_source!("mix-task-cancel-job")
      run = IngestionFixtures.create_provider_run!(source, "mix-task-cancel-job")

      job =
        ProviderIngestionWorker.new(%{
          provider: "test_publisher_api",
          manifest_path: @valid_manifest,
          provider_source_id: source.id,
          provider_run_id: run.id
        })
        |> Oban.insert!()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = Mix.Tasks.Hiraeth.Ingest.do_run(["--cancel", run.id, "--json"])
        end)

      assert %{
               "action" => "cancel",
               "status" => "cancelled",
               "run_id" => run_id,
               "correlated_oban_jobs" => 1,
               "cancelled_oban_jobs" => 1
             } = Jason.decode!(output)

      assert run_id == run.id
      assert Ash.get!(ProviderRun, run.id, authorize?: false).status == "cancelled"
      assert Hiraeth.Repo.get!(Oban.Job, job.id).state == "cancelled"
    end

    test "cancelled provider run preserves cancellation metadata after late phase progress" do
      source = IngestionFixtures.create_provider_source!("mix-task-cancel-preserve")
      run = IngestionFixtures.create_provider_run!(source, "mix-task-cancel-preserve")
      cancelled_at = ~U[2026-06-29 12:34:56Z]

      cancelled =
        run
        |> Ash.Changeset.for_update(:cancel, %{finished_at: cancelled_at})
        |> Ash.update!(actor: RunState.catalog_writer())

      RunState.mark_phase(cancelled.id, :provider_ingestion_worker, :succeeded, %{
        source_count: 10
      })

      updated = Ash.get!(ProviderRun, cancelled.id, authorize?: false)
      assert updated.status == "cancelled"
      assert updated.finished_at == cancelled_at

      assert get_in(updated.provenance, ["phases", "provider_ingestion_worker", "status"]) ==
               "succeeded"
    end

    test "worker refuses a cancelled provider run before executing phases" do
      source = IngestionFixtures.create_provider_source!("mix-task-worker-cancelled")
      run = IngestionFixtures.create_provider_run!(source, "mix-task-worker-cancelled")

      run
      |> Ash.Changeset.for_update(:cancel, %{finished_at: DateTime.utc_now(:second)})
      |> Ash.update!(actor: RunState.catalog_writer())

      assert {:cancel, message} =
               ProviderIngestionWorker.perform(%Oban.Job{
                 args: %{
                   "provider" => "test_publisher_api",
                   "manifest_path" => @valid_manifest,
                   "provider_source_id" => source.id,
                   "provider_run_id" => run.id
                 },
                 inserted_at: DateTime.utc_now()
               })

      assert message =~ "is cancelled"
      assert Ash.get!(ProviderRun, run.id, authorize?: false).status == "cancelled"
    end

    test "replay prepares approved candidate payloads and reports json without catalog apply" do
      candidate = IngestionFixtures.create_candidate!(%{suffix: "mix-task-replay"})

      candidate
      |> Ash.Changeset.for_update(:approve_for_apply, %{
        reviewer_note: "Mix task replay test approval"
      })
      |> Ash.update!(actor: IngestionFixtures.catalog_writer())

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--replay",
                     candidate.provider_run_id,
                     "--json"
                   ])
        end)

      assert %{
               "action" => "replay",
               "status" => "succeeded",
               "run_id" => replay_run_id,
               "replay_record_count" => 1
             } = Jason.decode!(output)

      assert replay_run_id == candidate.provider_run_id

      run = Ash.get!(ProviderRun, candidate.provider_run_id, authorize?: false)
      assert get_in(run.provenance, ["phases", "replay_snapshot", "status"]) == "succeeded"
    end

    test "missing run control commands return friendly errors" do
      missing_id = Ecto.UUID.generate()

      assert {:error, message} = Mix.Tasks.Hiraeth.Ingest.do_run(["--cancel", missing_id])
      assert message =~ "Provider run not found"
      refute message =~ "** ("

      assert {:error, message} = Mix.Tasks.Hiraeth.Ingest.do_run(["--replay", missing_id])
      assert message =~ "Provider run not found"
      refute message =~ "** ("
    end
  end

  defp decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp wait_for_ingestion_job(attempts \\ 200)

  defp wait_for_ingestion_job(0), do: flunk("timed out waiting for ingestion job")

  defp wait_for_ingestion_job(attempts) do
    if Hiraeth.Repo.exists?(from job in Oban.Job, where: job.queue == "ingestion") do
      :ok
    else
      receive do
      after
        10 -> wait_for_ingestion_job(attempts - 1)
      end
    end
  end
end
