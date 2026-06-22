defmodule Hiraeth.Oban.ProviderIngestionWorkerEnrichmentTest do
  use Hiraeth.DataCase, async: false

  import ExUnit.CaptureLog

  alias Hiraeth.Oban.ProviderIngestionWorker
  alias Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentCoverPipeline
  alias Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentImporter
  alias Hiraeth.TestSupport.ProviderIngestionWorkerEnrichmentSidecar

  @fallback_manifest_path Path.join([
                            File.cwd!(),
                            "test/support/fixtures/provider_manifests/valid_scrape_with_api_fallback.json"
                          ])

  setup do
    Application.put_env(:hiraeth, :provider_ingestion_worker_enrichment_test_pid, self())
    Application.put_env(:hiraeth, :sidecar_client, ProviderIngestionWorkerEnrichmentSidecar)
    Application.put_env(:hiraeth, :cover_pipeline, ProviderIngestionWorkerEnrichmentCoverPipeline)
    Application.put_env(:hiraeth, :importer, ProviderIngestionWorkerEnrichmentImporter)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)
      Application.delete_env(:hiraeth, :provider_ingestion_worker_scenario)
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
    end)

    :ok
  end

  describe "API fallback detail enrichment" do
    test "missing contributors and cover call sidecar detail once and merge only missing fields" do
      Application.put_env(:hiraeth, :provider_ingestion_worker_scenario, :enrichment)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, summary} = ProviderIngestionWorker.perform(build_job())
          assert summary.provider == "test_scrape_with_fallback"
          assert summary.record_count == 1
          assert summary.source_mode == "scrape"
        end)

      assert log =~ "enriched detail for 1 records"
      assert_fetch_config_has_api_fallback()

      assert_receive {:detail_called, "https://www.testscraper.com/catalog/test-book",
                      "test_scrape_with_fallback", detail_opts}

      assert detail_opts[:max_bytes] == 5_242_880

      refute_receive {:detail_called, _, _, _}
      assert_receive {:import_dataset, dataset}

      [record] = dataset.records
      assert record.contributors == [%{name: "Enriched Author", role: "author"}]
      assert record.cover.source_url == "https://images.testscraper.com/covers/enriched.jpg"
      assert record.cover.provider == "test_scrape_with_fallback"
      assert record.cover.rights_basis == "local_cache_permitted"
      assert record.cover.cache_policy == "cache_allowed"
      assert record.edition.isbn_13 == "9781939419545"
      assert record.edition.published_on == "2024-01-01"
      assert record.description == "original API description"
    end

    test "complete API fallback record does not call sidecar detail" do
      Application.put_env(:hiraeth, :provider_ingestion_worker_scenario, :complete)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, summary} = ProviderIngestionWorker.perform(build_job())
          assert summary.provider == "test_scrape_with_fallback"
          assert summary.record_count == 1
          assert summary.source_mode == "scrape"
        end)

      refute log =~ "enriched detail"
      assert_fetch_config_has_api_fallback()
      refute_receive {:detail_called, _, _, _}
      assert_receive {:import_dataset, dataset}

      [record] = dataset.records
      assert record.contributors == [%{name: "Complete Author", role: "author"}]
      assert record.cover.source_url == "https://images.testscraper.com/covers/complete-book.jpg"
    end

    test "sidecar detail timeout is graceful and leaves record to validation" do
      Application.put_env(:hiraeth, :provider_ingestion_worker_scenario, :timeout)

      log =
        capture_log([level: :info], fn ->
          assert {:error, findings} = ProviderIngestionWorker.perform(build_job())
          assert Enum.any?(findings, &(&1.reason == "at least one contributor is required"))
        end)

      assert log =~ "sidecar detail enrichment failed"
      assert log =~ "timeout"
      assert_fetch_config_has_api_fallback()

      assert_receive {:detail_called, "https://www.testscraper.com/catalog/timeout-book",
                      "test_scrape_with_fallback", _opts}

      refute_receive {:import_dataset, _dataset}
    end

    test "non-binary source_uri skips detail and falls through to validation" do
      Application.put_env(:hiraeth, :provider_ingestion_worker_scenario, :malformed)

      assert {:error, findings} = ProviderIngestionWorker.perform(build_job())

      assert Enum.any?(findings, &(&1.reason == "at least one contributor is required"))

      assert Enum.any?(
               findings,
               &(&1.reason == "cover source_url or no_cover_reason is required")
             )

      assert_fetch_config_has_api_fallback()
      refute_receive {:detail_called, _, _, _}
      refute_receive {:import_dataset, _dataset}
    end
  end

  defp assert_fetch_config_has_api_fallback do
    assert_receive {:scrape_config, scrape_config}
    assert scrape_config.config.api.type == "shopify"
    assert Map.has_key?(scrape_config.config.api, :allowed_vendors)

    assert_receive {:fetch_config, fetch_config}
    assert fetch_config.config.api.type == "shopify"
    assert Map.has_key?(fetch_config.config.api, :allowed_vendors)
  end

  defp build_job do
    %Oban.Job{
      args: %{
        "manifest_path" => @fallback_manifest_path,
        "provider" => "test_scrape_with_fallback"
      },
      worker: "Hiraeth.Oban.ProviderIngestionWorker",
      queue: :ingestion
    }
  end
end
