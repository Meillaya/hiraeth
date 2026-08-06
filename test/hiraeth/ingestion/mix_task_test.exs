defmodule Hiraeth.Ingestion.MixTaskTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{ProviderRun, ProviderSource}
  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.Repo
  alias Hiraeth.TestSupport.IngestionFixtures
  alias Mix.Tasks.Hiraeth.Ingest

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
          Ingest.do_run([
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
          Ingest.do_run([
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
      assert catch_exit(Ingest.run([])) == {:shutdown, 1}
    end

    test "invalid manifest exits 1" do
      assert catch_exit(
               Ingest.run([
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
                   Ingest.run([
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

  describe "operator conflict semantics" do
    setup do
      # Jobs must not execute inline here: the conflict cancel-and-replace flow
      # is what is under test, not the pipeline itself.
      Application.put_env(
        :hiraeth,
        Oban,
        Keyword.put(Application.get_env(:hiraeth, Oban), :testing, :manual)
      )

      :ok
    end

    test "operator run replaces a pending scheduled job and its queued run" do
      source = create_source_for!("test_publisher_api")

      scheduled_run =
        ProviderRun
        |> Ash.Changeset.for_create(:create, %{
          provider_source_id: source.id,
          status: "queued",
          requested_by: "provider_scheduler",
          run_key: "scheduled:2026-08-05T12:00:00Z",
          provenance: %{"scheduled" => true}
        })
        |> Ash.create!(actor: IngestionFixtures.catalog_writer())

      assert {:ok, scheduled_job} =
               Oban.insert(
                 ProviderIngestionWorker.new(%{
                   "scheduled" => true,
                   provider: "test_publisher_api",
                   manifest_path: @valid_manifest,
                   provider_source_id: source.id,
                   provider_run_id: scheduled_run.id
                 })
               )

      assert :ok =
               Ingest.do_run([
                 "--provider",
                 "test_publisher_api",
                 "--manifest",
                 @valid_manifest,
                 "--json"
               ])

      assert %{state: "cancelled"} = Repo.get(Oban.Job, scheduled_job.id)
      assert Ash.get!(ProviderRun, scheduled_run.id, authorize?: false).status == "cancelled"

      [operator_run] =
        provider_runs_for("test_publisher_api")
        |> Enum.filter(&(&1.requested_by == "mix hiraeth.ingest"))

      assert operator_run.status == "queued"

      assert [operator_job] =
               Repo.all(
                 from(job in Oban.Job,
                   where:
                     fragment("?->>? = ?", job.args, "provider_run_id", ^operator_run.id) and
                       job.state == "available"
                 )
               )

      refute operator_job.args["scheduled"] == true

      # Every queued operator run has exactly one live job; nothing is orphaned.
      assert Enum.all?(
               provider_runs_for("test_publisher_api"),
               &(&1.status != "queued" or queued_run_job_count(&1.id) == 1)
             )
    end
  end

  defp wait_for_ingestion_job(attempts \\ 200)

  defp wait_for_ingestion_job(0), do: flunk("timed out waiting for ingestion job")

  defp wait_for_ingestion_job(attempts) do
    import Ecto.Query

    if Repo.exists?(from job in Oban.Job, where: job.queue == "ingestion") do
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

  defp create_source_for!(provider) do
    ProviderSource
    |> Ash.Changeset.for_create(:create, %{
      stable_source_key: "publisher:#{provider}:api",
      provider_name: provider,
      source_kind: "publisher",
      ingestion_mode: "api",
      base_uri: "https://fixture.example.com/books",
      manifest_uri: @valid_manifest,
      allowed_hosts: ["fixture.example.com"],
      rate_limit_per_minute: 30,
      max_bytes: 1_048_576,
      checksum_algorithm: "sha256",
      required_checksum: "sha256:#{provider}",
      license_note: "Deterministic fixture provider for operator conflict tests.",
      enabled?: true,
      cadence_hours: 24
    })
    |> Ash.create!(actor: IngestionFixtures.catalog_writer())
  end

  defp queued_run_job_count(run_id) do
    import Ecto.Query

    Repo.one(
      from(job in Oban.Job,
        where: fragment("?->>? = ?", job.args, "provider_run_id", ^run_id),
        select: count(job.id)
      )
    ) || 0
  end
end
