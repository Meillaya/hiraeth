defmodule Hiraeth.Ingestion.MixTaskTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.ProviderRun

  require Ash.Query

  @valid_manifest Path.join([
                    File.cwd!(),
                    "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                  ])

  @invalid_manifest Path.join([
                      File.cwd!(),
                      "test/support/fixtures/provider_manifests/invalid_missing_fields.json"
                    ])

  alias Hiraeth.TestSupport.MixTaskMocks.{
    MockCoverPipeline,
    MockImporter,
    MockSidecarClient,
    MockUnhealthySidecarClient
  }

  # --- Test setup ---

  setup do
    Application.put_env(:hiraeth, :sidecar_client, MockSidecarClient)
    Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
    Application.put_env(:hiraeth, :importer, MockImporter)

    previous_oban_config = Application.get_env(:hiraeth, Oban)

    Application.put_env(
      :hiraeth,
      Oban,
      Keyword.put(previous_oban_config || [], :testing, :inline)
    )

    on_exit(fn ->
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
      Application.put_env(:hiraeth, Oban, previous_oban_config)
    end)

    :ok
  end

  # --- Tests ---

  describe "happy path" do
    test "valid provider ingests successfully" do
      task =
        Task.async(fn ->
          Mix.Tasks.Hiraeth.Ingest.do_run([
            "--provider",
            "test_publisher_api",
            "--manifest",
            @valid_manifest
          ])
        end)

      wait_for_ingestion_job()
      Oban.drain_queue(queue: :ingestion, with_safety: false)

      assert :ok = Task.await(task, 60_000)
    end

    test "valid provider creates a provider run before compatibility worker execution" do
      task =
        Task.async(fn ->
          Mix.Tasks.Hiraeth.Ingest.do_run([
            "--provider",
            "test_publisher_api",
            "--manifest",
            @valid_manifest
          ])
        end)

      wait_for_ingestion_job()
      Oban.drain_queue(queue: :ingestion, with_safety: false)

      assert :ok = Task.await(task, 60_000)

      assert [run] = provider_runs_for("test_publisher_api")
      assert run.requested_by == "mix hiraeth.ingest"
      assert run.status == "succeeded"
      assert run.run_key =~ "operator:test_publisher_api:"
      assert run.provenance["manifest_path"] == @valid_manifest
      assert run.provenance["destructive_apply"] == false
    end
  end

  describe "argument validation" do
    test "missing --provider exits 1" do
      assert catch_exit(Mix.Tasks.Hiraeth.Ingest.run([])) == {:shutdown, 1}
    end

    test "invalid manifest exits 1" do
      assert catch_exit(
               Mix.Tasks.Hiraeth.Ingest.run([
                 "--provider",
                 "test_publisher_api",
                 "--manifest",
                 @invalid_manifest
               ])
             ) == {:shutdown, 1}
    end
  end

  describe "sidecar health" do
    test "sidecar down exits 1 with message" do
      Application.put_env(:hiraeth, :sidecar_client, MockUnhealthySidecarClient)

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(
                   Mix.Tasks.Hiraeth.Ingest.run([
                     "--provider",
                     "test_publisher_api",
                     "--manifest",
                     @valid_manifest
                   ])
                 ) == {:shutdown, 1}
        end)

      assert output =~ "Scrapling sidecar is not running"
    end
  end

  defp wait_for_ingestion_job(attempts \\ 200)

  defp wait_for_ingestion_job(0), do: flunk("timed out waiting for ingestion job")

  defp wait_for_ingestion_job(attempts) do
    import Ecto.Query

    if Hiraeth.Repo.exists?(from job in Oban.Job, where: job.queue == "ingestion") do
      :ok
    else
      receive do
      after
        10 -> wait_for_ingestion_job(attempts - 1)
      end
    end
  end

  defp provider_runs_for(provider) do
    ProviderRun
    |> Ash.Query.load(:provider_source)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(
      &(&1.provider_source && &1.provider_source.stable_source_key =~ "publisher:#{provider}:")
    )
  end
end
