defmodule Hiraeth.Oban.ProviderIngestionWorkerEnrichmentTest do
  use Hiraeth.DataCase, async: false

  import ExUnit.CaptureLog

  alias Hiraeth.Oban.ProviderIngestionWorker

  require Ash.Query

  @fallback_manifest_path Path.join([
                            File.cwd!(),
                            "test/support/fixtures/provider_manifests/valid_scrape_with_api_fallback.json"
                          ])

  defmodule EnrichmentSidecarClient do
    def scrape(_provider_config, _opts \\ []) do
      {:error, "sidecar scrape failed with status 500"}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [incomplete_api_record()]}}
    end

    def detail(source_uri, vendor, opts \\ []) do
      send(test_pid(), {:detail_called, source_uri, vendor, opts})

      {:ok,
       %{
         "contributors" => [
           %{"name" => "Enriched Author", "role" => "author"}
         ],
         "cover" => %{"source_url" => "https://images.testscraper.com/covers/enriched.jpg"},
         "isbn_13" => "9781646050185",
         "published_on" => "2030-01-01",
         "description" => "detail description must not replace present description"
       }}
    end

    defp incomplete_api_record do
      base_record()
      |> Map.put(:contributors, [])
      |> put_in([:cover, :source_url], nil)
      |> put_in([:edition, :isbn_13], "9781939419545")
      |> put_in([:edition, :published_on], "2024-01-01")
      |> Map.put(:description, "original API description")
    end

    defp base_record do
      provider_slug = "test_scrape_with_fallback"
      source_uri = "https://www.testscraper.com/catalog/test-book"

      %{
        source_uri: source_uri,
        publisher: provider_slug,
        imprint: nil,
        source_product_id: "fallback-api-001",
        work: %{
          title: "Fallback API Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Fallback API Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [%{name: "Fallback Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => field_source(provider_slug, source_uri),
          "contributors" => field_source(provider_slug, source_uri),
          "publisher" => field_source(provider_slug, source_uri)
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/test-book.jpg",
          provider: provider_slug,
          rights_basis: "local_cache_permitted",
          cache_policy: "cache_allowed",
          attribution_text: nil,
          attribution_url: nil
        },
        missing_fields: %{},
        series: [],
        review_links: [],
        editorial_praise: [],
        description: nil,
        synopsis: nil,
        storefront_url: nil,
        source_sku: nil
      }
    end

    defp field_source(provider_slug, source_uri) do
      %{
        "provider" => provider_slug,
        "source_uri" => source_uri,
        "source_type" => "publisher_dataset",
        "rights_basis" => "public_domain"
      }
    end

    defp test_pid do
      Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)
    end
  end

  defmodule CompleteSidecarClient do
    def scrape(_provider_config, _opts \\ []) do
      {:error, "sidecar scrape failed with status 500"}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [complete_api_record()]}}
    end

    def detail(_source_uri, _vendor, _opts \\ []) do
      raise "detail should not be called for a complete API fallback record"
    end

    defp complete_api_record do
      complete_source_uri = "https://www.testscraper.com/catalog/complete-book"
      provider_slug = "test_scrape_with_fallback"

      %{
        source_uri: complete_source_uri,
        publisher: provider_slug,
        imprint: nil,
        source_product_id: "fallback-api-complete-001",
        work: %{
          title: "Complete API Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Complete API Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: "2024-02-01",
          isbn_13: "9781939419545"
        },
        contributors: [%{name: "Complete Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => field_source(provider_slug, complete_source_uri),
          "contributors" => field_source(provider_slug, complete_source_uri),
          "publisher" => field_source(provider_slug, complete_source_uri)
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/complete-book.jpg",
          provider: provider_slug,
          rights_basis: "local_cache_permitted",
          cache_policy: "cache_allowed",
          attribution_text: nil,
          attribution_url: nil
        },
        missing_fields: %{},
        series: [],
        review_links: [],
        editorial_praise: [],
        description: "complete API description",
        synopsis: nil,
        storefront_url: nil,
        source_sku: nil
      }
    end

    defp field_source(provider_slug, source_uri) do
      %{
        "provider" => provider_slug,
        "source_uri" => source_uri,
        "source_type" => "publisher_dataset",
        "rights_basis" => "public_domain"
      }
    end
  end

  defmodule TimeoutSidecarClient do
    def scrape(_provider_config, _opts \\ []) do
      {:error, "sidecar scrape failed with status 500"}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [record_missing_contributors()]}}
    end

    def detail(source_uri, vendor, opts \\ []) do
      send(test_pid(), {:detail_called, source_uri, vendor, opts})
      {:error, "timeout"}
    end

    defp record_missing_contributors do
      provider_slug = "test_scrape_with_fallback"
      source_uri = "https://www.testscraper.com/catalog/timeout-book"

      %{
        source_uri: source_uri,
        publisher: provider_slug,
        imprint: nil,
        source_product_id: "fallback-api-timeout-001",
        work: %{
          title: "Timeout API Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Timeout API Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => field_source(provider_slug, source_uri),
          "contributors" => field_source(provider_slug, source_uri),
          "publisher" => field_source(provider_slug, source_uri)
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/timeout-book.jpg",
          provider: provider_slug,
          rights_basis: "local_cache_permitted",
          cache_policy: "cache_allowed",
          attribution_text: nil,
          attribution_url: nil
        },
        missing_fields: %{isbn_13: "not available from source"},
        series: [],
        review_links: [],
        editorial_praise: [],
        description: nil,
        synopsis: nil,
        storefront_url: nil,
        source_sku: nil
      }
    end

    defp field_source(provider_slug, source_uri) do
      %{
        "provider" => provider_slug,
        "source_uri" => source_uri,
        "source_type" => "publisher_dataset",
        "rights_basis" => "public_domain"
      }
    end

    defp test_pid do
      Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)
    end
  end

  defmodule MalformedSourceUriSidecarClient do
    def scrape(_provider_config, _opts \\ []) do
      {:error, "sidecar scrape failed with status 500"}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [record_with_non_binary_source_uri()]}}
    end

    def detail(source_uri, vendor, opts \\ []) when is_binary(source_uri) do
      send(test_pid(), {:detail_called, source_uri, vendor, opts})
      {:error, "detail should not be called for malformed source_uri"}
    end

    defp record_with_non_binary_source_uri do
      provider_slug = "test_scrape_with_fallback"
      source_uri = 123

      %{
        source_uri: source_uri,
        publisher: provider_slug,
        imprint: nil,
        source_product_id: "fallback-api-malformed-001",
        work: %{
          title: "Malformed Source URI Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Malformed Source URI Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => field_source(provider_slug, source_uri),
          "contributors" => field_source(provider_slug, source_uri),
          "publisher" => field_source(provider_slug, source_uri)
        },
        cover: %{
          source_url: nil,
          provider: provider_slug,
          rights_basis: "local_cache_permitted",
          cache_policy: "cache_allowed",
          attribution_text: nil,
          attribution_url: nil
        },
        missing_fields: %{isbn_13: "not available from source"},
        series: [],
        review_links: [],
        editorial_praise: [],
        description: nil,
        synopsis: nil,
        storefront_url: nil,
        source_sku: nil
      }
    end

    defp field_source(provider_slug, source_uri) do
      %{
        "provider" => provider_slug,
        "source_uri" => source_uri,
        "source_type" => "publisher_dataset",
        "rights_basis" => "public_domain"
      }
    end

    defp test_pid do
      Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)
    end
  end

  defmodule MockCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config), do: {:ok, %{}}
  end

  defmodule ReportingImporter do
    def seed_provider!(dataset, _import_run) do
      send(
        Application.fetch_env!(:hiraeth, :provider_ingestion_worker_enrichment_test_pid),
        {:import_dataset, dataset}
      )

      {:ok,
       %{
         publishers: 1,
         editions: length(dataset.records),
         source_records: length(dataset.records)
       }}
    end
  end

  setup do
    Application.put_env(:hiraeth, :provider_ingestion_worker_enrichment_test_pid, self())
    Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
    Application.put_env(:hiraeth, :importer, ReportingImporter)

    on_exit(fn ->
      Application.delete_env(:hiraeth, :provider_ingestion_worker_enrichment_test_pid)
      Application.delete_env(:hiraeth, :sidecar_client)
      Application.delete_env(:hiraeth, :cover_pipeline)
      Application.delete_env(:hiraeth, :importer)
    end)

    :ok
  end

  describe "API fallback detail enrichment" do
    test "missing contributors and cover call sidecar detail once and merge only missing fields" do
      Application.put_env(:hiraeth, :sidecar_client, EnrichmentSidecarClient)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, summary} = ProviderIngestionWorker.perform(build_job())
          assert summary.provider == "test_scrape_with_fallback"
          assert summary.record_count == 1
          assert summary.source_mode == "scrape"
        end)

      assert log =~ "enriched detail for 1 records"

      assert_receive {:detail_called, "https://www.testscraper.com/catalog/test-book",
                      "test_scrape_with_fallback", _opts}

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
      Application.put_env(:hiraeth, :sidecar_client, CompleteSidecarClient)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, summary} = ProviderIngestionWorker.perform(build_job())
          assert summary.provider == "test_scrape_with_fallback"
          assert summary.record_count == 1
          assert summary.source_mode == "scrape"
        end)

      refute log =~ "enriched detail"
      refute_receive {:detail_called, _, _, _}
      assert_receive {:import_dataset, dataset}

      [record] = dataset.records
      assert record.contributors == [%{name: "Complete Author", role: "author"}]
      assert record.cover.source_url == "https://images.testscraper.com/covers/complete-book.jpg"
    end

    test "sidecar detail timeout is graceful and leaves record to validation" do
      Application.put_env(:hiraeth, :sidecar_client, TimeoutSidecarClient)

      log =
        capture_log([level: :info], fn ->
          assert {:error, findings} = ProviderIngestionWorker.perform(build_job())
          assert Enum.any?(findings, &(&1.reason == "at least one contributor is required"))
        end)

      assert log =~ "sidecar detail enrichment failed"
      assert log =~ "timeout"

      assert_receive {:detail_called, "https://www.testscraper.com/catalog/timeout-book",
                      "test_scrape_with_fallback", _opts}

      refute_receive {:import_dataset, _dataset}
    end

    test "non-binary source_uri skips detail and falls through to validation" do
      Application.put_env(:hiraeth, :sidecar_client, MalformedSourceUriSidecarClient)

      assert {:error, findings} = ProviderIngestionWorker.perform(build_job())

      assert Enum.any?(findings, &(&1.reason == "at least one contributor is required"))

      assert Enum.any?(
               findings,
               &(&1.reason == "cover source_url or no_cover_reason is required")
             )

      refute_receive {:detail_called, _, _, _}
      refute_receive {:import_dataset, _dataset}
    end
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
