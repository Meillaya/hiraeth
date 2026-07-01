defmodule Hiraeth.Ingestion.TelemetryTest do
  use Hiraeth.DataCase, async: false

  alias Hiraeth.Ingestion.{CoverCandidateRun, Phases, ProviderManifest, ProviderRun, Telemetry}
  alias Hiraeth.Oban.{ProviderIngestionWorker, ProviderSchedulerWorker}
  alias HiraethWeb.Telemetry, as: WebTelemetry
  alias Hiraeth.TestSupport.IngestionFixtures

  require Ash.Query

  @api_manifest_path Path.join([
                       File.cwd!(),
                       "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                     ])
  @tick_at ~U[2026-06-29 12:00:00Z]

  defmodule ParseFailureSidecarClient do
    def fetch(_provider_config, _opts \\ []),
      do: {:error, {:parse_failed, "sidecar parse failed"}}

    def scrape(_provider_config, _opts \\ []),
      do: {:error, {:parse_failed, "sidecar parse failed"}}
  end

  defmodule FailingCandidateCoverPipeline do
    def cache_cover_candidates!(candidates, _provider_config) do
      {:error, Enum.map(candidates, & &1.source_uri)}
    end
  end

  defmodule FailingLegacyCoverPipeline do
    def download_and_cache!(cover_urls, _provider_config) do
      {:error, Enum.map(cover_urls, & &1.source_url)}
    end
  end

  defmodule FailingDetailSidecarClient do
    def detail(_source_uri, _provider, _opts), do: {:error, {:parse_failed, "detail failed"}}
  end

  setup do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    events = [
      Telemetry.phase_event(),
      Telemetry.scheduler_tick_event(),
      Telemetry.sidecar_error_event(),
      Telemetry.queue_latency_event(),
      Telemetry.cover_cache_event()
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

    previous_client = Application.get_env(:hiraeth, :sidecar_client)
    previous_root = Application.get_env(:hiraeth, :source_snapshot_retention_root)

    root =
      Path.join(System.tmp_dir!(), "hiraeth-telemetry-#{System.unique_integer([:positive])}")

    Application.put_env(:hiraeth, :source_snapshot_retention_root, root)

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if previous_client do
        Application.put_env(:hiraeth, :sidecar_client, previous_client)
      else
        Application.delete_env(:hiraeth, :sidecar_client)
      end

      if previous_root do
        Application.put_env(:hiraeth, :source_snapshot_retention_root, previous_root)
      else
        Application.delete_env(:hiraeth, :source_snapshot_retention_root)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "failed sidecar phase emits sidecar and phase telemetry without provider payloads" do
    source = IngestionFixtures.create_provider_source!("telemetry-sidecar")
    run = IngestionFixtures.create_provider_run!(source, "telemetry-sidecar")
    Application.put_env(:hiraeth, :sidecar_client, ParseFailureSidecarClient)

    assert {:error, {:parse_failed, "sidecar parse failed"}} =
             Phases.FetchSnapshot.run(%{
               manifest_path: @api_manifest_path,
               provider_source_id: source.id,
               provider_run_id: run.id
             })

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :sidecar, :error],
                    sidecar_measurements, sidecar_metadata}

    assert sidecar_measurements == %{count: 1}
    assert sidecar_metadata.operation == "fetch"
    assert sidecar_metadata.error_code == :parse_failed
    refute Map.has_key?(sidecar_metadata, :message)
    refute Map.has_key?(sidecar_metadata, :source_uri)

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :phase, :stop], phase_measurements,
                    phase_metadata}

    assert phase_metadata.provider_run_id == run.id
    assert phase_metadata.provider_source_id == source.id
    assert phase_metadata.phase == :fetch_snapshot
    assert phase_metadata.status == :failed
    assert phase_metadata.error_code == :parse_failed
    assert phase_measurements.error_count == 1
    refute Map.has_key?(phase_metadata, :message)
  end

  test "scheduler worker emits queue latency and scheduler tick counts scoped to the requested source" do
    source = create_source!("telemetry-scheduler", ingestion_mode: "manifest", enabled?: true)

    assert {:ok, %{created: [_run], skipped: []}} =
             ProviderSchedulerWorker.perform(%Oban.Job{
               args: %{
                 "tick_at" => DateTime.to_iso8601(@tick_at),
                 "provider_source_id" => source.id
               },
               inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
             })

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :queue, :latency],
                    queue_measurements, queue_metadata}

    assert queue_metadata.worker == :provider_scheduler_worker
    assert queue_measurements.duration >= 0

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :scheduler, :tick],
                    tick_measurements, tick_metadata}

    assert tick_metadata.tick_at == "2026-06-29T12:00:00Z"
    assert tick_measurements.created_count == 1
    assert tick_measurements.skipped_count == 0
    assert tick_measurements.duration >= 0

    assert [%{provider_source_id: provider_source_id}] = provider_runs_for(source)
    assert provider_source_id == source.id
  end

  test "custom millisecond duration metrics preserve emitted millisecond values" do
    assert metric_measurement("hiraeth.ingestion.scheduler.tick.duration", %{duration: 300_000}) ==
             300_000

    assert metric_measurement("hiraeth.ingestion.queue.latency.duration", %{duration: 300_000}) ==
             300_000
  end

  test "telemetry helper metadata is whitelisted and drops secret-like fields" do
    unsafe_metadata = %{
      provider: "safe-provider",
      provider_run_id: "run-1",
      provider_source_id: "source-1",
      authorization: "Bearer secret",
      cookie: "session=secret",
      headers: %{"authorization" => "Bearer secret"},
      body: "raw payload",
      url: "https://example.test/private?token=secret",
      source_uri: "https://example.test/source",
      token: "secret"
    }

    Telemetry.queue_latency(:provider_ingestion_worker, DateTime.utc_now(), unsafe_metadata)

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :queue, :latency], _measurements,
                    metadata}

    assert metadata.provider == "safe-provider"
    assert metadata.provider_run_id == "run-1"
    assert metadata.provider_source_id == "source-1"
    assert metadata.worker == :provider_ingestion_worker

    for unsafe_key <- [:authorization, :cookie, :headers, :body, :url, :source_uri, :token] do
      refute Map.has_key?(metadata, unsafe_key)
    end

    Telemetry.sidecar_error("detail", :parse_failed, unsafe_metadata)

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :sidecar, :error], _measurements,
                    metadata}

    assert metadata.operation == "detail"
    assert metadata.error_code == :parse_failed
    assert metadata.provider == "safe-provider"

    for unsafe_key <- [:authorization, :cookie, :headers, :body, :url, :source_uri, :token] do
      refute Map.has_key?(metadata, unsafe_key)
    end
  end

  test "detail enrichment failures emit sidecar telemetry without source urls" do
    manifest = cover_manifest("deep_vellum_official_store", "cache_allowed")
    manifest = %{manifest | detail_enrichment: true}

    records = [
      %{
        source_uri: "https://publisher.example/books/detail-needed",
        work: %{title: "Detail Needed"},
        edition: %{},
        contributors: [],
        cover: %{}
      }
    ]

    assert {:ok, _normalized_records} =
             ProviderIngestionWorker.normalize_provider_records(
               records,
               manifest,
               FailingDetailSidecarClient
             )

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :sidecar, :error], measurements,
                    metadata}

    assert measurements == %{count: 1}
    assert metadata.operation == "detail"
    assert metadata.error_code == :parse_failed
    assert metadata.provider == "deep_vellum_official_store"
    refute Map.has_key?(metadata, :source_uri)
    refute Map.has_key?(metadata, :url)
  end

  test "quarantine and production cover candidate failure telemetry expose counts and stale-age signals" do
    candidate =
      IngestionFixtures.create_candidate!(%{
        suffix: "telemetry-quarantine",
        diff_classification: "invalid"
      })

    assert {:ok, %{quarantined_candidates: [quarantined_candidate]}} =
             Phases.QuarantineRun.run(%{provider_run_id: candidate.provider_run_id})

    assert quarantined_candidate.id == candidate.id

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :phase, :stop],
                    quarantine_measurements, quarantine_metadata}

    assert quarantine_metadata.phase == :quarantine_run
    assert quarantine_metadata.status == :succeeded
    assert quarantine_measurements.candidate_count == 1
    assert quarantine_measurements.rejected_count == 1
    assert quarantine_measurements.quarantine_age_seconds >= 0

    dataset = cover_dataset("telemetry-cover-candidate")
    manifest = cover_manifest("telemetry_cover_candidate", "cache_allowed")

    assert {:error, _reason} =
             CoverCandidateRun.cache_dataset_covers(
               dataset,
               manifest,
               FailingCandidateCoverPipeline
             )

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :cover, :cache], cover_measurements,
                    cover_metadata}

    assert cover_metadata.status == :failed
    assert is_binary(cover_metadata.provider_run_id)
    assert is_binary(cover_metadata.provider_source_id)
    assert cover_measurements.candidate_count == 2
    assert cover_measurements.failed_count == 0
    assert cover_measurements.error_count == 2
  end

  test "strict legacy cover cache failures emit sanitized cover telemetry" do
    dataset = cover_dataset("telemetry-cover-legacy")
    manifest = cover_manifest("telemetry_cover_legacy", "strict")

    assert {:error, _reason} =
             CoverCandidateRun.cache_dataset_covers(dataset, manifest, FailingLegacyCoverPipeline)

    assert_receive {:telemetry_event, [:hiraeth, :ingestion, :cover, :cache], cover_measurements,
                    cover_metadata}

    assert cover_metadata.status == :failed
    assert cover_metadata.provider == "telemetry_cover_legacy"
    refute Map.has_key?(cover_metadata, :source_uri)
    assert cover_measurements.candidate_count == 2
    assert cover_measurements.failed_count == 2
    assert cover_measurements.error_count == 2
  end

  defp metric_measurement(metric_name, measurements) do
    WebTelemetry.metrics()
    |> Enum.find(&(Enum.join(&1.name, ".") == metric_name))
    |> Map.fetch!(:measurement)
    |> apply_metric_measurement(measurements)
  end

  defp apply_metric_measurement(measurement, measurements) when is_function(measurement, 1),
    do: measurement.(measurements)

  defp apply_metric_measurement(measurement, measurements) when is_atom(measurement),
    do: Map.fetch!(measurements, measurement)

  defp cover_dataset(suffix) do
    %{
      file_checksum: "sha256-#{suffix}",
      file_path: "test/fixtures/#{suffix}.json",
      records: [
        cover_record("#{suffix}-one", "https://covers.example/#{suffix}-one.jpg"),
        cover_record("#{suffix}-two", "https://covers.example/#{suffix}-two.jpg")
      ]
    }
  end

  defp cover_record(title, cover_url) do
    %{
      source_uri: "https://publisher.example/books/#{title}",
      work: %{title: title},
      cover: %{
        source_url: cover_url,
        rights_basis: "local_cache_permitted",
        attribution_text: "Cover via fixture"
      }
    }
  end

  defp cover_manifest(provider, cover_cache_policy) do
    %ProviderManifest{
      provider: provider,
      name: provider,
      source_mode: "manifest",
      source_urls: ["https://publisher.example/catalog.json"],
      source_hosts: ["publisher.example"],
      cover_hosts: ["covers.example"],
      rate_limit: %{max_concurrency: 1, max_bytes: 1_048_576},
      permission_basis: "fixture",
      cover_cache_policy: cover_cache_policy
    }
  end

  defp create_source!(suffix, attrs) do
    IngestionFixtures.create_provider_source!(suffix)
    |> Ash.Changeset.for_update(:update, Map.new(attrs))
    |> Ash.update!(actor: IngestionFixtures.catalog_writer())
  end

  defp provider_runs_for(source) do
    ProviderRun
    |> Ash.Query.filter(provider_source_id == ^source.id)
    |> Ash.read!(authorize?: false)
  end
end
