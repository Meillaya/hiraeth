defmodule Hiraeth.Oban.ProviderIngestionWorkerTest do
  use Hiraeth.DataCase, async: true

  alias Hiraeth.Oban.ProviderIngestionWorker

  require Ash.Query

  @api_manifest_path Path.join([
                       File.cwd!(),
                       "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                     ])

  @scrape_manifest_path Path.join([
                          File.cwd!(),
                          "test/support/fixtures/provider_manifests/valid_scrape_manifest.json"
                        ])

  @fallback_manifest_path Path.join([
                            File.cwd!(),
                            "test/support/fixtures/provider_manifests/valid_scrape_with_api_fallback.json"
                          ])

  setup do
    Process.delete(:manifest_providers)
    :ok
  end

  # --- Mock modules ---

  defmodule MockSidecarClient do
    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [api_record()]}}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:ok, %{records: [scrape_record()]}}
    end

    def api_record do
      %{
        source_uri: "https://www.testpublisher.com/books/test-book",
        publisher: "Test Publisher",
        imprint: nil,
        source_product_id: "test-book-001",
        work: %{
          title: "Test Book Title",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Test Book Title",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [%{name: "Test Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => %{
            "provider" => "test_publisher_api",
            "source_uri" => "https://www.testpublisher.com/books/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "contributors" => %{
            "provider" => "test_publisher_api",
            "source_uri" => "https://www.testpublisher.com/books/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "publisher" => %{
            "provider" => "test_publisher_api",
            "source_uri" => "https://www.testpublisher.com/books/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          }
        },
        cover: %{
          source_url: "https://cdn.testpublisher.com/covers/test-book.jpg",
          provider: "test_publisher_api",
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

    def scrape_record do
      %{
        source_uri: "https://www.testscraper.com/catalog/test-book",
        publisher: "Test Scraper Publisher",
        imprint: nil,
        source_product_id: "scrape-book-001",
        work: %{
          title: "Test Scraped Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Test Scraped Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [%{name: "Test Scraper Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => %{
            "provider" => "test_publisher_scrape",
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "contributors" => %{
            "provider" => "test_publisher_scrape",
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "publisher" => %{
            "provider" => "test_publisher_scrape",
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          }
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/test-book.jpg",
          provider: "test_publisher_scrape",
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

    def fallback_api_record do
      provider_slug = "test_scrape_with_fallback"

      %{
        source_uri: "https://www.testscraper.com/catalog/test-book",
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
          "title" => %{
            "provider" => provider_slug,
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "contributors" => %{
            "provider" => provider_slug,
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "publisher" => %{
            "provider" => provider_slug,
            "source_uri" => "https://www.testscraper.com/catalog/test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          }
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/test-book.jpg",
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

    def fallback_scrape_record do
      provider_slug = "test_scrape_with_fallback"

      %{
        source_uri: "https://www.testscraper.com/catalog/scrape-test-book",
        publisher: provider_slug,
        imprint: nil,
        source_product_id: "fallback-scrape-001",
        work: %{
          title: "Fallback Scraped Book",
          subtitle: nil,
          original_title: nil,
          original_language_code: nil,
          subjects: nil,
          publication_state: "published"
        },
        edition: %{
          title: "Fallback Scraped Book",
          subtitle: nil,
          format: "paperback",
          language_code: nil,
          page_count: nil,
          dimensions: nil,
          published_on: nil,
          isbn_13: nil
        },
        contributors: [%{name: "Fallback Scraper Author", role: "author"}],
        curation: %{status: "approved"},
        displayed_fields: ["title", "contributors", "publisher"],
        field_sources: %{
          "title" => %{
            "provider" => provider_slug,
            "source_uri" => "https://www.testscraper.com/catalog/scrape-test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "contributors" => %{
            "provider" => provider_slug,
            "source_uri" => "https://www.testscraper.com/catalog/scrape-test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          },
          "publisher" => %{
            "provider" => provider_slug,
            "source_uri" => "https://www.testscraper.com/catalog/scrape-test-book",
            "source_type" => "publisher_dataset",
            "rights_basis" => "public_domain"
          }
        },
        cover: %{
          source_url: "https://images.testscraper.com/covers/scrape-test-book.jpg",
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
  end

  defmodule MockFailingSidecarClient do
    def fetch(_provider_config, _opts \\ []) do
      {:error, "sidecar fetch failed with status 500"}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:error, "sidecar scrape failed with status 500"}
    end
  end

  defmodule MockRateLimitSidecarClient do
    def fetch(_provider_config, _opts \\ []) do
      {:error, "429 too many requests"}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:error, "rate limit exceeded"}
    end
  end

  defmodule MockScrapeFailsFetchSucceedsClient do
    def scrape(_provider_config, _opts \\ []) do
      {:error, "sidecar scrape failed with status 500"}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [MockSidecarClient.fallback_api_record()]}}
    end
  end

  defmodule MockScrapeEmptyFetchSucceedsClient do
    def scrape(_provider_config, _opts \\ []) do
      {:ok, %{records: []}}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [MockSidecarClient.fallback_api_record()]}}
    end
  end

  defmodule MockScrapeOnlyClient do
    def scrape(_provider_config, _opts \\ []) do
      {:ok, %{records: [MockSidecarClient.fallback_scrape_record()]}}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:error, "fetch should not be called when scrape succeeds"}
    end
  end

  defmodule MockApiNeverScrapeClient do
    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [MockSidecarClient.api_record()]}}
    end

    def scrape(_provider_config, _opts \\ []) do
      raise "scrape should never be called in API mode"
    end
  end

  defmodule MockInvalidRecordsSidecarClient do
    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [invalid_record()]}}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:ok, %{records: [invalid_record()]}}
    end

    defp invalid_record do
      %{
        publisher: "Test Publisher",
        source_product_id: "invalid-001",
        work: %{title: nil},
        edition: %{title: nil},
        contributors: [],
        curation: %{status: "pending"},
        displayed_fields: [],
        field_sources: %{},
        cover: %{},
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
  end

  defmodule MockCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config) do
      {:ok, %{}}
    end
  end

  defmodule MockFailingCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config) do
      raise "cover cache failed: disk full"
    end
  end

  defmodule MockImporter do
    def seed_provider!(_dataset, _import_run) do
      {:ok, %{publishers: 1, editions: 1, source_records: 1}}
    end
  end

  # --- Test helpers ---

  def setup_mocks(_context) do
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

  defp build_args(manifest_path, provider) do
    %{"manifest_path" => manifest_path, "provider" => provider}
  end

  defp build_job(manifest_path, provider) do
    args = build_args(manifest_path, provider)

    %Oban.Job{
      args: args,
      worker: "Hiraeth.Oban.ProviderIngestionWorker",
      queue: :ingestion
    }
  end

  # --- Tests ---

  describe "happy path - API mode" do
    setup :setup_mocks

    test "completes full ingestion flow successfully" do
      job = build_job(@api_manifest_path, "test_publisher_api")

      assert {:ok, summary} = ProviderIngestionWorker.perform(job)
      assert summary.provider == "test_publisher_api"
      assert summary.record_count == 1
      assert summary.source_mode == "api"
    end
  end

  describe "happy path - scrape mode" do
    setup :setup_mocks

    test "completes full ingestion flow successfully" do
      job = build_job(@scrape_manifest_path, "test_publisher_scrape")

      assert {:ok, summary} = ProviderIngestionWorker.perform(job)
      assert summary.provider == "test_publisher_scrape"
      assert summary.record_count == 1
      assert summary.source_mode == "scrape"
    end
  end

  describe "failure rollback - sidecar error" do
    setup do
      Application.put_env(:hiraeth, :sidecar_client, MockFailingSidecarClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)
    end

    test "returns error when sidecar fails" do
      job = build_job(@api_manifest_path, "test_publisher_api")

      assert {:error, reason} = ProviderIngestionWorker.perform(job)
      assert reason =~ "sidecar fetch failed"
    end

    test "zero DB writes when sidecar fails mid-fetch" do
      args = build_args(@api_manifest_path, "test_publisher_api")

      assert {:error, _reason} = Oban.Testing.perform_job(ProviderIngestionWorker, args, [])

      source_count =
        Hiraeth.Sources.SourceRecord
        |> Ash.Query.filter(provider: "test_publisher_api")
        |> Ash.read!(authorize?: false)
        |> length()

      assert source_count == 0
    end
  end

  describe "rate limit snooze" do
    setup do
      Application.put_env(:hiraeth, :sidecar_client, MockRateLimitSidecarClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)
    end

    test "snoozes when sidecar returns rate-limit error" do
      job = build_job(@api_manifest_path, "test_publisher_api")

      assert {:snooze, 60} = ProviderIngestionWorker.perform(job)
    end
  end

  describe "validation failure - invalid records" do
    setup do
      Application.put_env(:hiraeth, :sidecar_client, MockInvalidRecordsSidecarClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)
    end

    test "returns validation error for invalid records" do
      args = build_args(@api_manifest_path, "test_publisher_api")

      assert {:error, findings} = Oban.Testing.perform_job(ProviderIngestionWorker, args, [])
      assert is_list(findings)
      assert length(findings) > 0
    end

    test "zero DB writes when validation fails" do
      args = build_args(@api_manifest_path, "test_publisher_api")

      assert {:error, _findings} = Oban.Testing.perform_job(ProviderIngestionWorker, args, [])

      source_count =
        Hiraeth.Sources.SourceRecord
        |> Ash.Query.filter(provider: "test_publisher_api")
        |> Ash.read!(authorize?: false)
        |> length()

      assert source_count == 0
    end
  end

  describe "manifest load failure" do
    setup :setup_mocks

    test "returns error for non-existent manifest" do
      job = build_job("/nonexistent/manifest.json", "nonexistent")

      assert {:error, reason} = ProviderIngestionWorker.perform(job)
      assert reason =~ "manifest load failed"
    end
  end

  describe "cover cache failure" do
    setup do
      Application.put_env(:hiraeth, :sidecar_client, MockSidecarClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockFailingCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)
    end

    test "returns error when cover cache fails" do
      job = build_job(@api_manifest_path, "test_publisher_api")

      assert {:error, reason} = ProviderIngestionWorker.perform(job)
      assert is_binary(reason)
      assert reason =~ "cover cache failed"
    end

    test "zero DB writes when cover cache fails" do
      args = build_args(@api_manifest_path, "test_publisher_api")

      assert {:error, _reason} = Oban.Testing.perform_job(ProviderIngestionWorker, args, [])

      source_count =
        Hiraeth.Sources.SourceRecord
        |> Ash.Query.filter(provider: "test_publisher_api")
        |> Ash.read!(authorize?: false)
        |> length()

      assert source_count == 0
    end
  end

  describe "unique job" do
    setup do
      Application.put_env(:hiraeth, :sidecar_client, MockSidecarClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)
    end

    test "rejects duplicate enqueue for same provider" do
      job_args = %{"manifest_path" => @api_manifest_path, "provider" => "test_publisher_api"}

      assert {:ok, job1} =
               Oban.insert(ProviderIngestionWorker.new(job_args))

      assert {:ok, job2} =
               Oban.insert(ProviderIngestionWorker.new(job_args))

      # Both should reference the same job (unique constraint)
      assert job1.id == job2.id
    end
  end

  describe "idempotent re-run" do
    setup :setup_mocks

    test "running twice does not create duplicate source records" do
      job = build_job(@api_manifest_path, "test_publisher_api")

      assert {:ok, _summary} = ProviderIngestionWorker.perform(job)

      source_count_after_first =
        Hiraeth.Sources.SourceRecord
        |> Ash.read!(authorize?: false)
        |> length()

      assert {:ok, _summary} = ProviderIngestionWorker.perform(job)

      source_count_after_second =
        Hiraeth.Sources.SourceRecord
        |> Ash.read!(authorize?: false)
        |> length()

      assert source_count_after_second == source_count_after_first
    end
  end

  describe "scrape-first with API fallback" do
    test "falls back to API on scrape error when API config exists" do
      Application.put_env(:hiraeth, :sidecar_client, MockScrapeFailsFetchSucceedsClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)

      job = build_job(@fallback_manifest_path, "test_scrape_with_fallback")

      assert {:ok, summary} = ProviderIngestionWorker.perform(job)
      assert summary.provider == "test_scrape_with_fallback"
      assert summary.record_count == 1
      assert summary.source_mode == "scrape"
    end

    test "falls back to API on empty scrape result when API config exists" do
      Application.put_env(:hiraeth, :sidecar_client, MockScrapeEmptyFetchSucceedsClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)

      job = build_job(@fallback_manifest_path, "test_scrape_with_fallback")

      assert {:ok, summary} = ProviderIngestionWorker.perform(job)
      assert summary.provider == "test_scrape_with_fallback"
      assert summary.record_count == 1
      assert summary.source_mode == "scrape"
    end

    test "returns scrape error when scrape fails and no API config exists" do
      Application.put_env(:hiraeth, :sidecar_client, MockFailingSidecarClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)

      job = build_job(@scrape_manifest_path, "test_publisher_scrape")

      assert {:error, reason} = ProviderIngestionWorker.perform(job)
      assert reason =~ "sidecar scrape failed"
    end

    test "successful non-empty scrape does not fall back to fetch" do
      Application.put_env(:hiraeth, :sidecar_client, MockScrapeOnlyClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)

      job = build_job(@fallback_manifest_path, "test_scrape_with_fallback")

      assert {:ok, summary} = ProviderIngestionWorker.perform(job)
      assert summary.provider == "test_scrape_with_fallback"
      assert summary.record_count == 1
      assert summary.source_mode == "scrape"
    end

    test "explicit api source_mode calls fetch directly and never scrape" do
      Application.put_env(:hiraeth, :sidecar_client, MockApiNeverScrapeClient)
      Application.put_env(:hiraeth, :cover_pipeline, MockCoverPipeline)
      Application.put_env(:hiraeth, :importer, MockImporter)

      on_exit(fn ->
        Application.delete_env(:hiraeth, :sidecar_client)
        Application.delete_env(:hiraeth, :cover_pipeline)
        Application.delete_env(:hiraeth, :importer)
      end)

      job = build_job(@api_manifest_path, "test_publisher_api")

      assert {:ok, summary} = ProviderIngestionWorker.perform(job)
      assert summary.provider == "test_publisher_api"
      assert summary.record_count == 1
      assert summary.source_mode == "api"
    end
  end

  describe "compute_file_checksum/1" do
    test "same records produce same checksum, different records produce different checksum" do
      record1 = %{source_uri: "https://example.com/1", title: "Book 1"}
      record2 = %{source_uri: "https://example.com/2", title: "Book 2"}

      checksum_a = ProviderIngestionWorker.compute_file_checksum([record1, record2])
      checksum_b = ProviderIngestionWorker.compute_file_checksum([record1, record2])
      checksum_c = ProviderIngestionWorker.compute_file_checksum([record2, record1])
      checksum_d = ProviderIngestionWorker.compute_file_checksum([record1])

      assert checksum_a == checksum_b
      assert checksum_a == checksum_c
      assert checksum_a != checksum_d
    end

    test "works with both atom and string keys" do
      record_atom = %{source_uri: "https://example.com/1", title: "Book 1"}
      record_string = %{"source_uri" => "https://example.com/1", "title" => "Book 1"}

      checksum_atom = ProviderIngestionWorker.compute_file_checksum([record_atom])
      checksum_string = ProviderIngestionWorker.compute_file_checksum([record_string])

      assert checksum_atom == checksum_string
    end
  end
end
