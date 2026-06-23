defmodule Hiraeth.Ingestion.MixTaskTest do
  use Hiraeth.DataCase, async: false

  @valid_manifest Path.join([
                    File.cwd!(),
                    "test/support/fixtures/provider_manifests/valid_api_manifest.json"
                  ])

  @invalid_manifest Path.join([
                      File.cwd!(),
                      "test/support/fixtures/provider_manifests/invalid_missing_fields.json"
                    ])

  @implicit_scrape_manifest Path.join([
                              File.cwd!(),
                              "test/support/fixtures/provider_manifests/implicit_scrape_manifest.json"
                            ])

  @deep_vellum_manifest Path.join([
                          File.cwd!(),
                          "priv/catalog_sources/provider_manifests/deep_vellum_official_store.json"
                        ])

  # --- Mock modules ---

  defmodule MockSidecarClient do
    def health(_opts \\ []) do
      {:ok, %{status: "ok", scrapling: true}}
    end

    def fetch(_provider_config, _opts \\ []) do
      {:ok, %{records: [api_record()]}}
    end

    def scrape(_provider_config, _opts \\ []) do
      {:ok, %{records: [scrape_record()]}}
    end

    def detail(_source_uri, _provider, _opts) do
      {:ok, %{}}
    end

    defp api_record do
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

    defp scrape_record do
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
  end

  defmodule MockUnhealthySidecarClient do
    def health(_opts \\ []) do
      {:error, "connection refused"}
    end
  end

  defmodule MockCoverPipeline do
    def download_and_cache!(_cover_urls, _provider_config) do
      {:ok, %{}}
    end
  end

  defmodule MockImporter do
    def seed_provider!(_dataset, _import_run) do
      {:ok, %{publishers: 0, editions: 0, source_records: 0}}
    end
  end

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

      Process.sleep(100)
      Oban.drain_queue(queue: :ingestion, with_safety: false)

      assert :ok = Task.await(task, 60_000)
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

  describe "dry-run mode selection" do
    test "manifest with spider config and no source_mode uses scrape mode" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_scrape_implicit",
                     "--manifest",
                     @implicit_scrape_manifest,
                     "--dry-run"
                   ])
        end)

      assert output =~ "effective_source_mode=scrape"
      assert output =~ "first_record_title=Test Scraped Book"
    end

    test "manifest with source_mode: api uses api mode" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_api",
                     "--manifest",
                     @valid_manifest,
                     "--dry-run"
                   ])
        end)

      assert output =~ "effective_source_mode=api"
      assert output =~ "first_record_title=Test Book Title"
      assert output =~ "Dry-run validation passed"
    end

    test "dry-run reports expected_record_count mismatch without persisting" do
      manifest_path =
        @valid_manifest
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("expected_record_count", 2)
        |> write_temp_manifest()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "test_publisher_api",
                     "--manifest",
                     manifest_path,
                     "--dry-run"
                   ])
        end)

      assert output =~ "expected_record_count 2 does not match fetched record count 1"
      assert output =~ "Dry-run completed with validation issues"
    after
      cleanup_temp_manifests()
    end

    test "dry-run prints effective_source_mode=scrape for Deep Vellum manifest" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Mix.Tasks.Hiraeth.Ingest.do_run([
                     "--provider",
                     "deep_vellum_official_store",
                     "--manifest",
                     @deep_vellum_manifest,
                     "--dry-run"
                   ])
        end)

      assert output =~ "effective_source_mode=scrape"
    end
  end

  defp write_temp_manifest(manifest) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hiraeth_mix_task_manifest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "manifest.json")
    File.write!(path, Jason.encode!(manifest))
    path
  end

  defp cleanup_temp_manifests do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "hiraeth_mix_task_manifest_test_"))
    |> Enum.each(fn dir ->
      File.rm_rf!(Path.join(System.tmp_dir!(), dir))
    end)
  end
end
